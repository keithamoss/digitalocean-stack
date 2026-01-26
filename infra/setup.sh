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

# Add non-root user to docker group
DOCKER_USER="keith"
echo "==> Adding $DOCKER_USER to docker group"
usermod -aG docker "$DOCKER_USER"
echo "User $DOCKER_USER added to docker group. They will need to log out and back in for changes to take effect."

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

# Install acme.sh for Let's Encrypt certificate management
# - Certificate issuance is handled by individual site publish scripts
# - Installing as DOCKER_USER to avoid sudo/permission issues
echo "==> Installing acme.sh as $DOCKER_USER"
if [ ! -d "/home/$DOCKER_USER/.acme.sh" ]; then
    su - "$DOCKER_USER" -c 'curl https://get.acme.sh | sh'
    su - "$DOCKER_USER" -c '~/.acme.sh/acme.sh --version'
else
    echo "acme.sh already installed for $DOCKER_USER, skipping"
fi
