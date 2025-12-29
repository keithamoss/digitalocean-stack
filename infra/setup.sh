#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] ${BASH_COMMAND:-unknown command} failed" >&2' ERR

echo "==> Checking privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo/root." >&2
    exit 1
fi

# Base system update
echo "==> Updating system packages"
apt update -y
apt upgrade -y

# Install prerequisites
echo "==> Installing prerequisites"
command -v git >/dev/null 2>&1 || apt install -y git
command -v curl >/dev/null 2>&1 || apt install -y curl
dpkg -s ca-certificates >/dev/null 2>&1 || apt install -y ca-certificates

# Add Docker's official GPG key
echo "==> Adding Docker GPG key"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources
echo "==> Adding Docker apt source"
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update -y

# Install Docker Engine and Docker Compose
echo "==> Installing Docker"
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify installation
systemctl is-active --quiet docker || systemctl start docker
docker --version

declare -r STACK_DIR=${STACK_DIR:-/apps/stack}
declare -r CERT_DIR=${CERT_DIR:-$STACK_DIR/nginx/certs}

# Fetch the stack repo
echo "==> Fetching stack repo into $STACK_DIR"
mkdir -p /apps
if [ -d "$STACK_DIR/.git" ]; then
    git -C "$STACK_DIR" pull --ff-only
elif [ -d "$STACK_DIR" ]; then
    echo "Existing $STACK_DIR is not a git repo; refusing to overwrite. Move it aside and retry." >&2
    exit 1
else
    git clone https://github.com/keithamoss/digitalocean-stack.git "$STACK_DIR"
fi
cd "$STACK_DIR"

# Placeholder for secrets
# TODO: populate /demsausage/secrets/, /nginx/secrets/, /redis/conf/users.acl

# Let's Encrypt via acme.sh (Cloudflare DNS-01)
# - Requires CF_Token (Cloudflare Zone:DNS:Edit) exported before running.
# - Installs acme.sh as root and issues staging certs into nginx/certs.

mkdir -p "$CERT_DIR"

if [ -z "${CF_Token:-}" ]; then
    echo "CF_Token not set; skipping ACME issuance. Export CF_Token and rerun the ACME block." >&2
else
    echo "==> Installing acme.sh"
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --version

    echo "==> Issuing staging certs via Cloudflare DNS-01"
    CF_Token=$CF_Token ~/.acme.sh/acme.sh --issue --dns dns_cf --server letsencrypt \
        -d staging.democracysausage.org \
        -d staging-admin.democracysausage.org \
        -d staging-rq.democracysausage.org \
        --keylength ec-256

    echo "==> Installing certs into $CERT_DIR"
    CF_Token=$CF_Token ~/.acme.sh/acme.sh --install-cert -d staging.democracysausage.org --ecc \
        --key-file $CERT_DIR/democracysausage.org.key \
        --fullchain-file $CERT_DIR/democracysausage.org.fullchain.pem
fi
