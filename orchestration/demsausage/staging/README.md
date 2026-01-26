# Demsausage Staging Publish/Unpublish Workflow

To control whether local nginx proxies to the demsausage staging services:

## Prerequisites

- Run as a regular user with docker group access (not root/sudo)
- `CF_TOKEN` set in `orchestration/secrets/cloudflare.env` (Cloudflare Zone:DNS:Edit API token)
- acme.sh installed (via `infra/setup.sh`)

## Publish (enable local proxy)

    ./publish.sh

This script:
1. Loads certificate configuration from `cert.conf`
2. Issues/installs Let's Encrypt certificates via acme.sh + Cloudflare DNS-01 if needed
3. Copies nginx configs from `demsausage/nginx/conf.d/` into `nginx/conf.d/demsausage`
4. Reloads nginx via `orchestration/nginx.sh` (downloads artifacts)

If certificates are already valid and configs haven't changed, it skips unnecessary operations.

## Unpublish (disable local proxy)

    ./unpublish.sh

This removes the nginx configs from `nginx/conf.d/demsausage` and reloads nginx via `orchestration/nginx.sh --skip-download`. If nothing was published, it skips the reload.

Note: Certificates remain installed; unpublishing only removes nginx configuration.

## Notes

- Certificate domains are configured in `cert.conf` 
- Nginx configs live under `demsausage/nginx/conf.d/` and are copied into `nginx/conf.d/demsausage` (no symlinks)
- Use this workflow when moving staging services between hosts to avoid double proxying
