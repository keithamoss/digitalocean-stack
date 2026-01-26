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

# Early check for restic encryption key (fail fast before installing packages)
echo "==> Checking for restic encryption key"
RESTIC_KEY_FILE="$STACK_DIR/backups/secrets/restic.key"
if [ ! -f "$RESTIC_KEY_FILE" ]; then
    echo ""
    echo "⚠️  ERROR: Restic encryption key not found at $RESTIC_KEY_FILE"
    echo ""
    echo "For DISASTER RECOVERY (restoring from existing backups):"
    echo "  1. Restore the key from your password manager to:"
    echo "     $RESTIC_KEY_FILE"
    echo "  2. Set permissions: chmod 600 $RESTIC_KEY_FILE"
    echo "  3. Re-run this setup script"
    echo ""
    echo "For NEW INSTALLATION (creating backups for the first time):"
    echo "  Run: mkdir -p \"$(dirname "$RESTIC_KEY_FILE")\" && openssl rand -base64 32 > \"$RESTIC_KEY_FILE\" && chmod 600 \"$RESTIC_KEY_FILE\""
    echo "  Then: BACKUP THIS KEY TO YOUR PASSWORD MANAGER!"
    echo ""
    exit 1
fi
echo "✓ Restic encryption key found at $RESTIC_KEY_FILE"

# Install backup tools
echo "==> Installing restic for Foundry backups"
if ! command -v restic >/dev/null 2>&1; then
    apt install -y restic
    echo "restic installed: $(restic version)"
else
    echo "restic already installed, skipping"
fi

# Set proper permissions for restic key (already validated above)
chmod 600 "$RESTIC_KEY_FILE"
chown "$DOCKER_USER:$DOCKER_USER" "$RESTIC_KEY_FILE"

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
