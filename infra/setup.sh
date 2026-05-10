#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] ${BASH_COMMAND:-unknown command} failed" >&2' ERR

echo "==> Checking privileges"
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo/root." >&2
    exit 1
fi

# Resolve the deploy user and stack directory early — fail fast before touching anything.
# $SUDO_USER is set by sudo to the invoking user and is always present when run correctly.
DOCKER_USER="${SUDO_USER:?SUDO_USER is not set — run this script with sudo, not as root directly}"
if ! id "$DOCKER_USER" >/dev/null 2>&1; then
    echo "ERROR: SUDO_USER '$DOCKER_USER' is not a valid user account on this system." >&2
    exit 1
fi
declare -r STACK_DIR=${STACK_DIR:-/apps/stack}

# Temp dir for AWS CLI installer; cleaned up on any exit (success, error, or interrupt).
AWSCLI_TMP=""
trap '[ -n "$AWSCLI_TMP" ] && rm -rf "$AWSCLI_TMP"' EXIT

# Set timezone to AWST (Australia/Perth)
echo "==> Configuring timezone"
if [ "$(timedatectl show -p Timezone --value)" != "Australia/Perth" ]; then
    timedatectl set-timezone Australia/Perth
    echo "Timezone set to Australia/Perth (AWST)"
else
    echo "Timezone already set to Australia/Perth (AWST)"
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
# acl: required by install-systemd.sh and orchestration/db.sh for setfacl on log directories
dpkg -s acl >/dev/null 2>&1 || apt install -y acl
# jq: required by backup monitoring Discord notifications (discord-lib.sh)
command -v jq >/dev/null 2>&1 || apt install -y jq
# unzip: required for AWS CLI v2 installation
command -v unzip >/dev/null 2>&1 || apt install -y unzip

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

# Add non-root user to docker group so they can run docker commands without sudo.
# The orchestration scripts (orchestration/*.sh) are run as this user, not as root.
# DOCKER_USER and STACK_DIR are resolved at the top of this script.
echo "==> Adding $DOCKER_USER to docker group"
usermod -aG docker "$DOCKER_USER"
echo "User $DOCKER_USER added to docker group. They will need to log out and back in for changes to take effect."

# Fetch the stack repo
echo "==> Fetching stack repo into $STACK_DIR"
mkdir -p /apps
FRESH_CLONE=false
if [ -d "$STACK_DIR/.git" ]; then
    git -C "$STACK_DIR" pull --ff-only
elif [ -d "$STACK_DIR" ]; then
    echo "Existing $STACK_DIR is not a git repo; refusing to overwrite. Move it aside and retry." >&2
    exit 1
else
    git clone https://github.com/keithamoss/digitalocean-stack.git "$STACK_DIR"
    FRESH_CLONE=true
fi
cd "$STACK_DIR"

# Ensure the stack directory is owned by the deploy user, not root.
# Only on a fresh clone: on re-runs, db/data/ is owned by the postgres container user
# (UID 999), and a recursive chown would break it on the next container start.
if [ "$FRESH_CLONE" = true ]; then
    chown -R "$DOCKER_USER:$DOCKER_USER" "$STACK_DIR"
    echo "Stack directory ownership set to $DOCKER_USER"
fi

# Create symlink for user-independent paths (used in logrotate configs and systemd units)
echo "==> Creating symlink /opt/digitalocean-stack -> $STACK_DIR"
if [ -L "/opt/digitalocean-stack" ]; then
    CURRENT_TARGET=$(readlink -f /opt/digitalocean-stack)
    if [ "$CURRENT_TARGET" != "$STACK_DIR" ]; then
        echo "Updating symlink from '$CURRENT_TARGET' to '$STACK_DIR'"
        ln -sfn "$STACK_DIR" /opt/digitalocean-stack
    else
        echo "Symlink already points to correct location"
    fi
elif [ -e "/opt/digitalocean-stack" ]; then
    echo "ERROR: /opt/digitalocean-stack exists but is not a symlink" >&2
    exit 1
else
    ln -s "$STACK_DIR" /opt/digitalocean-stack
    echo "Created symlink /opt/digitalocean-stack -> $STACK_DIR"
fi

# Early check for restic encryption key (fail fast before installing backup tools)
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

# Check for AWS credentials (required for all backup operations: pgBackRest WAL archiving,
# restic Foundry/configs/logs repos, and S3 cost monitoring)
echo "==> Checking for AWS credentials"
AWS_ENV_FILE="$STACK_DIR/backups/secrets/aws.env"
if [ ! -f "$AWS_ENV_FILE" ]; then
    echo ""
    echo "⚠️  ERROR: AWS credentials not found at $AWS_ENV_FILE"
    echo ""
    echo "For DISASTER RECOVERY: restore your credentials from the password manager:"
    echo "  $AWS_ENV_FILE"
    echo ""
    echo "For NEW INSTALLATION: copy the template and fill in your IAM credentials:"
    echo "  cp \"$STACK_DIR/backups/secrets/templates/aws.env\" \"$AWS_ENV_FILE\""
    echo "  # Edit $AWS_ENV_FILE and add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    echo ""
    exit 1
fi
echo "✓ AWS credentials found at $AWS_ENV_FILE"

# Validate that credentials are actually populated (not just an unfilled template copy)
if ! grep -qE '^export AWS_ACCESS_KEY_ID=.+' "$AWS_ENV_FILE"; then
    echo ""
    echo "⚠️  ERROR: AWS_ACCESS_KEY_ID is empty in $AWS_ENV_FILE"
    echo "  Edit the file and fill in your IAM credentials."
    echo ""
    exit 1
fi

# Warn if Discord webhook is missing — non-blocking, but all alerts will be silent without it
DISCORD_ENV_FILE="$STACK_DIR/backups/secrets/discord.env"
if [ ! -f "$DISCORD_ENV_FILE" ]; then
    echo ""
    echo "⚠️  WARNING: Discord webhook not configured at $DISCORD_ENV_FILE"
    echo "  Backup failure alerts and heartbeat notifications will be silently skipped."
    echo "  To enable: cp \"$STACK_DIR/backups/secrets/templates/discord.env\" \"$DISCORD_ENV_FILE\""
    echo "  Then edit it to add your webhook URL."
    echo ""
fi

# Install backup tools
echo "==> Installing restic for Foundry backups"
if ! command -v restic >/dev/null 2>&1; then
    apt install -y restic
    echo "restic installed: $(restic version)"
else
    echo "restic already installed, skipping"
fi

# Install aws CLI v2 for logs sync
# Not available via apt — installed from the official AWS binary.
# Primary target is Raspberry Pi (aarch64) but x86_64 is also supported.
echo "==> Installing aws CLI v2 for logs sync"
if ! command -v aws >/dev/null 2>&1; then
    AWSCLI_ARCH=$(uname -m)
    case "$AWSCLI_ARCH" in
        aarch64) ;; # Raspberry Pi 64-bit
        x86_64)  ;; # Intel/AMD
        *) echo "ERROR: Unsupported architecture for AWS CLI install: $AWSCLI_ARCH" >&2; exit 1 ;;
    esac
    AWSCLI_TMP=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" -o "$AWSCLI_TMP/awscliv2.zip"
    unzip -q "$AWSCLI_TMP/awscliv2.zip" -d "$AWSCLI_TMP"
    "$AWSCLI_TMP/aws/install"
    echo "aws CLI installed: $(aws --version)"
else
    echo "aws CLI already installed, skipping"
fi

# Set proper permissions for restic key (already validated above)
chmod 600 "$RESTIC_KEY_FILE"
chown "$DOCKER_USER:$DOCKER_USER" "$RESTIC_KEY_FILE"

# Secure all secret files across repository
echo "==> Securing secret files across repository"
SECRETS_DIRS=(
    "$STACK_DIR/backups/secrets"       # Backup AWS, Discord, restic keys
    "$STACK_DIR/db/secrets"             # Database credentials
    "$STACK_DIR/demsausage/secrets"     # Demsausage app secrets
    "$STACK_DIR/foundry/secrets"        # Foundry VTT secrets
    "$STACK_DIR/nginx/secrets"          # Nginx/SSL secrets
    "$STACK_DIR/orchestration/secrets"  # Orchestration secrets
    "$STACK_DIR/secrets"                # Root-level secrets
    "$STACK_DIR/auto-redeploy/secrets"  # Auto-redeploy Discord webhook and GitHub token
    # Note: secrets-tmpl/ intentionally excluded (templates)
)

for dir in "${SECRETS_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        # Find all .env and .key files, excluding README and .gitkeep
        find "$dir" -maxdepth 1 -type f \( -name "*.env" -o -name "*.key" \) ! -name "README*" ! -name ".gitkeep" -print0 | while IFS= read -r -d '' file; do
            chmod 600 "$file"
            chown "$DOCKER_USER:$DOCKER_USER" "$file"
        done
        echo "  ✓ Secured secrets in $dir"
    fi
done

# Exception: backups/secrets/aws.env needs to be readable (644) so postgres user
# in the database container can read it via Docker secret mount for WAL archiving
if [ -f "$STACK_DIR/backups/secrets/aws.env" ]; then
    chmod 644 "$STACK_DIR/backups/secrets/aws.env"
    echo "  ⓘ backups/secrets/aws.env set to 644 (readable by postgres for WAL archiving)"
fi

# Secure Redis users.acl if it exists
# 640 (not 600) so the Redis container process (running as a different UID) can read it via group access
if [ -f "$STACK_DIR/redis/conf/users.acl" ]; then
    chmod 640 "$STACK_DIR/redis/conf/users.acl"
    chown "$DOCKER_USER:$DOCKER_USER" "$STACK_DIR/redis/conf/users.acl"
    echo "  ✓ Secured redis/conf/users.acl"
fi

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

# Deploy logrotate configs for all services
echo "==> Deploying logrotate configs"
"$STACK_DIR/infra/logrotate.d/deploy-logrotate.sh"

# Install backup systemd units, timers, log directories, and ACLs.
# This is idempotent — safe to re-run on updates.
echo "==> Installing backup systemd units"
"$STACK_DIR/backups/install-systemd.sh"

# Install auto-redeploy systemd units, script, and log directory.
# This is idempotent — safe to re-run on updates.
echo "==> Installing auto-redeploy systemd units"
"$STACK_DIR/auto-redeploy/install.sh"

# Warn if auto-redeploy secrets are missing — non-blocking
AUTO_REDEPLOY_DISCORD="$STACK_DIR/auto-redeploy/secrets/discord.env"
if [ ! -f "$AUTO_REDEPLOY_DISCORD" ]; then
    echo ""
    echo "⚠️  WARNING: Auto-redeploy Discord webhook not configured at $AUTO_REDEPLOY_DISCORD"
    echo "  Deployment alerts will be silently skipped without it."
    echo "  To enable: cp \"$STACK_DIR/auto-redeploy/secrets/templates/discord.env\" \"$AUTO_REDEPLOY_DISCORD\""
    echo "  Then edit it to add your webhook URL."
    echo ""
fi

AUTO_REDEPLOY_GITHUB="$STACK_DIR/auto-redeploy/secrets/github.env"
if [ ! -f "$AUTO_REDEPLOY_GITHUB" ]; then
    echo "⚠️  WARNING: Auto-redeploy GitHub token not configured at $AUTO_REDEPLOY_GITHUB"
    echo "  1-minute polling requires a token (unauthenticated limit: 60 req/hr)."
    echo "  Without it, set OnUnitInactiveSec=5min in auto-redeploy.timer."
    echo "  To enable: cp \"$STACK_DIR/auto-redeploy/secrets/templates/github.env\" \"$AUTO_REDEPLOY_GITHUB\""
    echo "  Then edit it to add your fine-grained PAT (read-only Actions scope)."
    echo ""
fi

echo ""
echo "✓ Setup complete!"
echo ""
echo "=========================================================="
echo " POST-SETUP STEPS (run as $DOCKER_USER, not root)"
echo "=========================================================="
echo ""
echo " NOTE: Log out and back in first so the docker group change takes effect."
echo ""
echo " 1. Bring up services (run from $STACK_DIR/orchestration/):" 
echo "      ./db.sh && ./redis.sh && ./nginx.sh && ./foundry.sh && ./cloudflared-pi-hosting.sh"
echo ""
echo " 2. NEW INSTALLATION ONLY — skip on disaster recovery (repos already exist):"
echo "    Initialise restic backup repositories:"
echo "      $STACK_DIR/backups/foundry/init-foundry-backup.sh"
echo "      $STACK_DIR/backups/configs/init-configs-backup.sh"
echo "      $STACK_DIR/backups/logs/init-logs-backup.sh"
echo ""
echo " 3. NEW INSTALLATION ONLY — skip on disaster recovery (stanza already exists):"
echo "    Initialise pgBackRest stanza and run first full backup:"
echo "      docker exec db /usr/local/bin/pgbackrest-wrapper --stanza=main stanza-create"
echo "      docker exec db /usr/local/bin/pgbackrest-wrapper --stanza=main --type=full backup"
echo ""
echo " 4. Start backup timers immediately (or reboot — they are already enabled):"
echo "      sudo systemctl start consolidated-backup.timer backup-heartbeat.timer"
echo "      sudo systemctl start postgresql-log-archive.timer log-archive.timer"
echo "      sudo systemctl start restore-test.timer s3-cost-report.timer operational-backup.timer"
echo ""
echo " 5. Start auto-redeploy timer (or reboot — it is already enabled):"
echo "      sudo systemctl start auto-redeploy.timer"
echo "    Then enable a deployment target by running its publish.sh, e.g.:"
echo "      $STACK_DIR/orchestration/demsausage/staging/publish.sh"
echo ""
