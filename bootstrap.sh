#!/usr/bin/env bash
set -euo pipefail

# Reference bootstrap for a headless WordPress stack on Podman.
# It does not configure DNS, install WordPress, or create the application
# password. Review it before running. Validated with `bash -n` only until the
# full VM validation.
#
# The CMS is expected to be noindex at the proxy. Do not disable search
# indexing in WordPress: `blog_public` must stay at 1 so Yoast does not mark
# the front content as noindex.

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      cat <<'EOF'
Usage: bootstrap.sh [--dry-run]

Environment:
  FRONT_DOMAIN   Public front domain (e.g. example.com)
  CMS_DOMAIN     CMS domain (e.g. cms.example.com)
  ACME_EMAIL     Let's Encrypt email
  FRONT_IMAGE    Front image (default localhost/example-front:1)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "Do not run this script as root. Use an unprivileged user." >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "Podman is required." >&2
  exit 1
fi

PODMAN_VERSION="$(podman --version | awk '{print $3}')"
if [ "$(printf '%s\n' "5.0.0" "$PODMAN_VERSION" | sort -V | head -n1)" != "5.0.0" ]; then
  echo "Podman 5.x is required for Quadlet. Found: $PODMAN_VERSION" >&2
  exit 1
fi

if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "No systemd user session. Enable lingering and log in again." >&2
  exit 1
fi

FRONT_DOMAIN="${FRONT_DOMAIN:-}"
CMS_DOMAIN="${CMS_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
FRONT_IMAGE="${FRONT_IMAGE:-localhost/example-front:1}"

if [ -z "$FRONT_DOMAIN" ]; then
  read -rp "Front domain [example.com]: " FRONT_DOMAIN
  FRONT_DOMAIN="${FRONT_DOMAIN:-example.com}"
fi

if [ -z "$CMS_DOMAIN" ]; then
  read -rp "CMS domain [cms.example.com]: " CMS_DOMAIN
  CMS_DOMAIN="${CMS_DOMAIN:-cms.example.com}"
fi

if [ -z "$ACME_EMAIL" ]; then
  read -rp "Email for TLS: " ACME_EMAIL
fi

BASE="$HOME/headless"
QUADLET="$HOME/.config/containers/systemd"

run() {
  if $DRY_RUN; then
    printf 'dry-run: %s\n' "$*"
  else
    "$@"
  fi
}

write_file() {
  local path="$1"
  if $DRY_RUN; then
    echo "dry-run: write $path" >&2
    cat >/dev/null
    return
  fi
  mkdir -p "$(dirname "$path")"
  if [ -e "$path" ]; then
    cp "$path" "$path.bak.$(date +%s)"
  fi
  cat >"$path"
}

ensure_secret() {
  local name="$1"
  if podman secret inspect "$name" >/dev/null 2>&1; then
    echo "Secret $name already exists."
    return
  fi
  if $DRY_RUN; then
    echo "dry-run: create secret $name"
    return
  fi
  openssl rand -base64 32 | podman secret create "$name" -
  echo "Secret $name created."
}

wait_health() {
  local name="$1"
  for _ in $(seq 1 30); do
    if podman healthcheck run "$name" >/dev/null 2>&1; then
      echo "$name is healthy."
      return 0
    fi
    sleep 2
  done
  echo "$name did not pass the healthcheck. Check: podman logs $name" >&2
  return 1
}

if ! $DRY_RUN; then
  mkdir -p "$BASE" "$QUADLET"
fi

write_file "$QUADLET/headless.network" <<'EOF'
[Network]
NetworkName=headless
EOF

for volume in wp_html db_data caddy_data caddy_config; do
  write_file "$QUADLET/$volume.volume" <<EOF
[Volume]
VolumeName=$volume
EOF
done

ensure_secret db_root_password
ensure_secret db_password

write_file "$QUADLET/mariadb.container" <<'EOF'
[Unit]
Description=MariaDB for headless WordPress
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/library/mariadb:11.4
ContainerName=mariadb
Network=headless.network
Volume=db_data.volume:/var/lib/mysql:Z
Secret=db_root_password,type=mount,target=db_root_password
Secret=db_password,type=mount,target=db_password
Environment=MARIADB_DATABASE=wordpress
Environment=MARIADB_USER=wordpress
Environment=MARIADB_ROOT_PASSWORD_FILE=/run/secrets/db_root_password
Environment=MARIADB_PASSWORD_FILE=/run/secrets/db_password
HealthCmd=healthcheck.sh --connect --innodb_initialized
HealthInterval=10s
HealthRetries=10
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

write_file "$QUADLET/wordpress.container" <<EOF
[Unit]
Description=Headless WordPress
After=mariadb.service
Requires=mariadb.service

[Container]
Image=docker.io/library/wordpress:php8.3-apache
ContainerName=wordpress
Network=headless.network
Volume=wp_html.volume:/var/www/html:Z
Secret=db_password,type=mount,target=db_password
Environment=WORDPRESS_DB_HOST=mariadb:3306
Environment=WORDPRESS_DB_NAME=wordpress
Environment=WORDPRESS_DB_USER=wordpress
Environment=WORDPRESS_DB_PASSWORD_FILE=/run/secrets/db_password
Environment="WORDPRESS_CONFIG_EXTRA=define('WP_HOME','https://$CMS_DOMAIN'); define('WP_SITEURL','https://$CMS_DOMAIN'); define('FORCE_SSL_ADMIN', true); define('DISALLOW_FILE_EDIT', true); define('WP_DEBUG', false); define('WP_ENVIRONMENT_TYPE', 'production'); define('AUTOMATIC_UPDATER_DISABLED', true);"
HealthCmd=curl -fsS http://localhost/wp-login.php >/dev/null
HealthInterval=15s
HealthRetries=10
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

write_file "$BASE/Caddyfile" <<EOF
{
  email $ACME_EMAIL
}

$FRONT_DOMAIN {
  encode zstd gzip
  reverse_proxy front:4321

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    -Server
  }
}

$CMS_DOMAIN {
  @blocked path /xmlrpc.php /wp-config.php /wp-config-sample.php
  handle @blocked {
    respond 403
  }

  @admin path /wp-admin/* /wp-login.php /wp-json/* /wp-content/* /wp-includes/*
  handle @admin {
    reverse_proxy wordpress:80
  }

  handle {
    redir https://$FRONT_DOMAIN{uri} 302
  }

  header {
    X-Robots-Tag "noindex, nofollow"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    -Server
  }
}
EOF

write_file "$QUADLET/caddy.container" <<EOF
[Unit]
Description=Caddy edge
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/library/caddy:2
ContainerName=caddy
Network=headless.network
PublishPort=80:80
PublishPort=443:443
PublishPort=443:443/udp
Volume=caddy_data.volume:/data:Z
Volume=caddy_config.volume:/config:Z
Volume=$BASE/Caddyfile:/etc/caddy/Caddyfile:ro,Z

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

write_file "$QUADLET/front.container" <<EOF
[Unit]
Description=Headless front
After=wordpress.service
Requires=wordpress.service

[Container]
Image=$FRONT_IMAGE
ContainerName=front
Network=headless.network
Environment=HOST=0.0.0.0
Environment=PORT=4321
Environment=SITE_URL=https://$FRONT_DOMAIN
Environment=WP_BASE_URL=http://wordpress:80
Environment=WP_READ_USER=front-reader
Secret=wp_read_password,type=env,target=WP_READ_PASSWORD
HealthCmd=wget -qO- http://localhost:4321/ >/dev/null
HealthInterval=15s
HealthRetries=10

[Service]
Restart=always

[Install]
WantedBy=default.target
EOF

run systemctl --user daemon-reload
run systemctl --user start mariadb
if ! $DRY_RUN; then wait_health mariadb; fi
run systemctl --user start wordpress
if ! $DRY_RUN; then wait_health wordpress; fi
run systemctl --user start caddy

echo
echo "Next steps:"
echo "1. Open https://$CMS_DOMAIN/wp-admin/install.php and create the administrator."
echo "2. Enable 2FA. Do not disable search indexing in WordPress: the CMS is"
echo "   already noindex at the proxy, and blog_public must stay at 1 so Yoast"
echo "   does not mark the front content as noindex."
echo "3. Create the front-reader user and its application password."
echo "4. Store the password:"
echo "   printf '%s' 'APP_PASSWORD' | podman secret create wp_read_password -"
echo "5. Build the front image and start it:"
echo "   podman build -t $FRONT_IMAGE ."
echo "   systemctl --user start front"
echo "6. Verify: https://$FRONT_DOMAIN/ and https://$CMS_DOMAIN/wp-login.php"
