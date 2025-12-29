# Nginx TLS with acme.sh + Cloudflare DNS-01

For Raspberry Pi or DigitalOcean hosts, the common provisioning script `infra/setup.sh` installs acme.sh and issues the staging certs into `nginx/certs` when `CF_Token` is set. Use that flow there; for other environments, follow equivalent acme.sh + Cloudflare DNS-01 steps (install acme.sh, `--issue`, then `--install-cert` to `./certs`).

1. Create a Cloudflare API token scoped to **Zone:DNS:Edit** for the domain.
2. Issue with Let’s Encrypt using acme.sh and Cloudflare DNS-01, then install to `./certs` (binds to `/etc/nginx/certs` in the container) as in `infra/setup.sh`.
   Ensure file permissions keep the private key readable only by the account running nginx/cloudflared on the host.
4. Keep Cloudflare SSL mode at **Full** (or **Full Strict** if you switch to an Origin Cert/validated chain) and firewall ports 80/443 on the droplet to Cloudflare IP ranges plus your admin IPs.
5. For Pi + tunnel: point the `cloudflared` ingress to `https://localhost:443` (or your chosen TLS port) to keep the origin encrypted.

   Cloudflare Tunnel notes
   - We target the origin by IP (e.g. `https://192.168.4.162:443`); set “Origin Server Name” to the cert hostname (e.g. `staging.democracysausage.org`) so SNI/verify match the Let’s Encrypt cert.
   - Keep TLS verify on; avoid `noTLSVerify` except for debugging.
   - DNS for each hostname should be a single proxied CNAME to the tunnel target (`<uuid>.cfargotunnel.com`). Remove any A/AAAA pointing at private/Cloudflare IPs to avoid Error 1000.
   - The tunnel connector must be able to reach the IP you configured in Service; if you switch to a hostname Service later, ensure it resolves privately to the origin (split-horizon or hosts override).

Certificates are expected at `/etc/nginx/certs/democracysausage.org.fullchain.pem` and `/etc/nginx/certs/democracysausage.org.key` inside the container; update paths in the server blocks if you choose different names.
