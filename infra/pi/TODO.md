# Network setup (Review and write-up)
review unifi bespoke config
port 9 for the home pi
port 16 for the hosting pi

Turned on more UniFi Cybersecure active detections

# Pi assembly
Case: https://kksb-cases.com/pages/assembly-instruction-kksb-hat-case-for-raspberry-pi-5
PoE: https://www.waveshare.com/wiki/PoE_HAT_(G)

Ref: https://www.raspberrypi.com/news/using-m-2-hat-with-raspberry-pi-5/

# Pi imaging (Review and write-up)
rpi-imnager:
had to unmount the drive first so it appeared in the list
custom os config: enable SSH, set username+password
then could flash
raspi-config to change boot order

# Software install
https://docs.docker.com/engine/install/debian/
https://docs.docker.com/compose/install/linux/

# Cloudflared
Should we disable auto-update?
Should we set `restart: unless-stopped`?

# Review Cloudflared logs
e.g. Is this still happening?

cloudflared-1  | 2025-11-22T05:15:03Z ERR Cannot determine default origin certificate path. No file cert.pem in [~/.cloudflared ~/.cloudflare-warp ~/cloudflare-warp /etc/cloudflared /usr/local/etc/cloudflared]. You need to specify the origin certificate path by specifying the origincert option in the configuration file, or set TUNNEL_ORIGIN_CERT environment variable originCertPath=

# How to manage IP address allow-listing for Mapa?

# Cloudflare cache busting
Do we still need it?
Is it working?

# Make a script to update cloudflare_real_ip.conf
https://www.cloudflare.com/en-au/ips/

# Disable password auth

# Harden SSH daemon config

# Harden SSH file system ownership and permissions on the Pi

# Consider SSH over CloudFlare tunnel