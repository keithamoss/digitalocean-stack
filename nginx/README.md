# Nginx TLS with acme.sh + Cloudflare DNS-01

## Setup

1. Run `infra/setup.sh` to install acme.sh as a non-root user (no sudo required for certificate operations).
2. Create a Cloudflare API token scoped to **Zone:DNS:Edit** for the domain and add it to `orchestration/secrets/cloudflare.env` as `CF_TOKEN`.
3. Certificate issuance and installation is handled automatically by individual site publish scripts (e.g., `orchestration/demsausage/staging/publish.sh`), which:
   - Read domain configuration from their local `cert.conf` file
   - Issue certificates via acme.sh + Cloudflare DNS-01 if needed
   - Install certificates to `nginx/certs` (binds to `/etc/nginx/certs` in the container)
   - Reload nginx automatically when certificates change

## Cloudflare Settings

- Keep Cloudflare SSL mode at **Full** (or **Full Strict** if you switch to an Origin Cert/validated chain)
- Firewall ports 80/443 on the droplet to Cloudflare IP ranges plus your admin IPs
- For Pi + tunnel: point the `cloudflared` ingress to `https://localhost:443` (or your chosen TLS port) to keep the origin encrypted

## Cloudflare Tunnel Configuration

- We target the origin by IP (e.g. `https://192.168.4.162:443`); set "Origin Server Name" to the cert hostname (e.g. `staging.democracysausage.org`) so SNI/verify match the Let's Encrypt cert.
- Keep TLS verify on; avoid `noTLSVerify` except for debugging.
- DNS for each hostname should be a single proxied CNAME to the tunnel target (`<uuid>.cfargotunnel.com`). Remove any A/AAAA pointing at private/Cloudflare IPs to avoid Error 1000.
- The tunnel connector must be able to reach the IP you configured in Service; if you switch to a hostname Service later, ensure it resolves privately to the origin (split-horizon or hosts override).

## Certificate Location

Certificates are installed to `nginx/certs/` (e.g., `democracysausage.org.fullchain.pem` and `democracysausage.org.key`), which is bound to `/etc/nginx/certs` inside the container. Update paths in the server blocks if you choose different names.