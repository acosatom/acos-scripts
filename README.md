# acos-scripts

Reference scripts for a headless WordPress stack on Podman.

## What it does

`bootstrap.sh` prepares a rootless Podman host for a small headless WordPress
deployment. It writes Quadlet units for MariaDB, WordPress, the front and Caddy,
creates the database secrets, starts MariaDB, WordPress and Caddy, and prints the
steps that still need a human.

The generated layout is:

```text
Internet -> Caddy :80/:443
  front domain -> front:4321
  cms domain   -> wordpress:80
  wordpress    -> mariadb:3306 (no published port)
```

## Requirements

- Linux with a systemd user session.
- Rootless Podman 5.x (Quadlet is required).
- `openssl`.
- Two DNS names pointing to the host: one for the front and one for the CMS.
- Ports 80 and 443 available.
- A front image that reads content over the internal WordPress REST endpoint.
  The script does not build it.

## Quick start

```bash
git clone <repository-url>
cd acos-scripts
chmod +x bootstrap.sh
./bootstrap.sh --dry-run
./bootstrap.sh
```

You can pass the domains and the TLS email as environment variables:

```bash
FRONT_DOMAIN=example.com \
CMS_DOMAIN=cms.example.com \
ACME_EMAIL=admin@example.com \
./bootstrap.sh
```

The front image can be changed with `FRONT_IMAGE`.

## What it does not do

- Configure DNS.
- Install WordPress. The script prints the installer URL.
- Create the WordPress administrator, enable 2FA or create the front-reader
  application password.
- Build the front image.
- Configure backups, monitoring or a WAF.
- Validate the full stack in a clean VM.

## Security notes

- The script refuses to run as root.
- Database passwords are generated locally and stored with `podman secret`.
- No secret values are written to the repository or printed.
- The CMS is expected to be `noindex` at the proxy. Keep `blog_public=1` in
  WordPress so Yoast does not mark the front content as `noindex`; the CMS host
  is protected by the proxy header, `robots.txt` and the redirect.
- Review every generated file before starting the services.

## Validation status

Draft. The script has been checked with `bash -n` only. It must be run end to end
in a clean Fedora or Debian VM with Podman 5.x before being treated as validated.

## License

No license has been chosen yet.
