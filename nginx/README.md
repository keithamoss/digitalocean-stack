# Nginx TLS with acme.sh + Cloudflare DNS-01

Install acme.sh (no root needed):

```bash
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --version
```

1. Create a Cloudflare API token scoped to **Zone:DNS:Edit** for the domain.
2. Issue with Let’s Encrypt (specify the CA explicitly):
   ```bash
  export CF_Token=YOUR_CF_TOKEN
  ~/.acme.sh/acme.sh --issue --dns dns_cf --server letsencrypt \
     -d staging.democracysausage.org \
     -d staging-admin.democracysausage.org \
     -d staging-rq.democracysausage.org \
     --keylength ec-256
   ```
3. Install certs to the host path that is mounted into Nginx (`./certs` → `/etc/nginx/certs` in the container):
   ```bash
   ~/.acme.sh/acme.sh --install-cert -d staging.democracysausage.org --ecc \
      --key-file ./certs/democracysausage.org.key \
      --fullchain-file ./certs/democracysausage.org.fullchain.pem
   ```
   Ensure file permissions keep the key readable only by you on the host.
4. Keep Cloudflare SSL mode at **Full** (or **Full Strict** if you switch to an Origin Cert/validated chain) and firewall ports 80/443 on the droplet to Cloudflare IP ranges plus your admin IPs.
5. For Pi + tunnel: point the `cloudflared` ingress to `https://localhost:443` (or your chosen TLS port) to keep the origin encrypted.

Certificates are expected at `/etc/nginx/certs/democracysausage.org.fullchain.pem` and `/etc/nginx/certs/democracysausage.org.key` inside the container; update paths in the server blocks if you choose different names.
