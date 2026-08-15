# auto-redeploy

Polls GitHub Actions and automatically deploys services on successful builds.

## Architecture

- **Main script**: `/usr/local/bin/auto-redeploy.sh` (installed from `auto-redeploy/auto-redeploy.sh`)
- **Timer**: `auto-redeploy.timer` — fires 1 minute after previous run exits (`OnUnitInactiveSec=1min`)
- **Service**: `auto-redeploy.service` — oneshot, runs the main script
- **Targets**: symlinks in `auto-redeploy/enabled/*.conf` → `orchestration/{service}/{env}/auto-redeploy.conf`
- **State**: `auto-redeploy/state/{target-name}.json` (gitignored, created on first deployment)
- **Logs**: `logs/auto-redeploy/auto-redeploy.log`

## Installation

```bash
sudo ./auto-redeploy/install.sh
```

Then populate secrets (see `auto-redeploy/secrets/README.md`) and start the timer:

```bash
sudo systemctl start auto-redeploy.timer
```

## Enabling a Target

Run the service's `publish.sh` (e.g. `orchestration/demsausage/staging/publish.sh`).
It creates the symlink in `auto-redeploy/enabled/`. Then commit the symlink.

## Target Config Reference

Target configs live at `orchestration/{service}/{env}/auto-redeploy.conf`.

Required fields:

- `GITHUB_REPO`: GitHub repository in `owner/repo` format.
- `WORKFLOW_FILE`: Workflow file name in `.github/workflows/`.
- `BRANCH`: Branch to track.
- `COMPOSE_FILE`: Compose file to deploy.

Optional fields:

- `WATCH_TIMEOUT_MINS` (default `15`): Max watch-loop time for queued/in-progress runs.
- `CLOUDFLARE_PURGE` (default `false`): Whether to purge Cloudflare after deploy.
- `CLOUDFLARE_ENV`: Env file for Cloudflare credentials when purge is enabled.

After successful container updates, auto-redeploy always refreshes nginx via:

- `orchestration/nginx.sh --skip-download`

This avoids hardcoding container names and ensures upstream mappings are refreshed consistently.

Auto-redeploy always skips deployment when the newest successful run has the same `head_sha` as the last deployed SHA.
For same-SHA recovery/restart operations, use manual orchestration scripts:

- `orchestration/demsausage/staging/deploy.sh`
- `orchestration/demsausage/production/deploy.sh`

Example:

```bash
GITHUB_REPO="keithamoss/demsausage"
WORKFLOW_FILE="staging_cicd.yml"
BRANCH="staging"
COMPOSE_FILE="${STACK_DIR}/demsausage/staging.yml"
WATCH_TIMEOUT_MINS="10"
CLOUDFLARE_PURGE="true"
CLOUDFLARE_ENV="${STACK_DIR}/orchestration/secrets/cloudflare.env"
```

## Disabling a Target

Run the service's `unpublish.sh`. It removes the symlink. Then commit the removal.

## Operations

```bash
# Timer status
sudo systemctl status auto-redeploy.timer
sudo systemctl list-timers | grep auto-redeploy

# Recent runs (journald)
sudo journalctl -u auto-redeploy.service -n 50

# Live log
tail -f /opt/digitalocean-stack/logs/auto-redeploy/auto-redeploy.log

# Current deployment state for all targets
for f in /opt/digitalocean-stack/auto-redeploy/state/*.json; do
    echo "=== $(basename "$f" .json) ==="
    jq . "$f"
done

# Manually trigger (for testing)
sudo systemctl start auto-redeploy.service
```

## Dry-run mode

```bash
DRY_RUN=true sudo -E /usr/local/bin/auto-redeploy.sh
```

Logs what it would do without pulling images or restarting containers.

## Troubleshooting

**Target not deploying:**
```bash
ls -la /opt/digitalocean-stack/auto-redeploy/enabled/
grep "demsausage-staging" /opt/digitalocean-stack/logs/auto-redeploy/auto-redeploy.log | tail -30
```

**API rate limit:**
```bash
grep -i "rate limit" /opt/digitalocean-stack/logs/auto-redeploy/auto-redeploy.log
# Fix: add GITHUB_TOKEN to auto-redeploy/secrets/github.env
```

**Script fails:**
```bash
sudo -u deploy bash -x /usr/local/bin/auto-redeploy.sh
```

## Adding a New Service

1. Create `orchestration/{service}/{env}/auto-redeploy.conf` with the target's config
2. Create `orchestration/{service}/{env}/deploy.sh`, `publish.sh`, `unpublish.sh`
3. Run `publish.sh` — it creates the symlink in `auto-redeploy/enabled/`
4. Commit the symlink
