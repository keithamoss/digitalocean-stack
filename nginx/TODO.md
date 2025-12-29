# Automatically refresh/regenerate cloudflare_real_ip.conf somehow

# Firewall off the server so only our CloudFlare tunnel (Pi) or CloudFlare (DO) can even reach NGinx

# Run nginx as the non-root user and lock down /nginx/certs/