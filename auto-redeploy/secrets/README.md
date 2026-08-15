# auto-redeploy Secrets Directory

This directory stores sensitive credentials used by the auto-redeploy service.

## Files to Create

Copy templates from `templates/` and fill in actual values:

### 1. Discord Webhook (required for notifications)

**File**: `discord.env`
**Template**: `templates/discord.env`

```bash
cp templates/discord.env discord.env
# Edit discord.env and add your webhook URL
```

Create a webhook in your Discord server under: Server Settings → Integrations → Webhooks

### 2. GitHub Personal Access Token (required for 1-minute polling)

**File**: `github.env`
**Template**: `templates/github.env`

```bash
cp templates/github.env github.env
# Edit github.env and add your token
```

Create a fine-grained PAT at https://github.com/settings/tokens with:
- **Read-only** `Actions` scope only
- No other permissions required

Without a token, polling is unauthenticated (60 req/hr limit). Set `OnUnitInactiveSec=5min`
in the timer to stay within the limit.

## Security

- `discord.env` and `github.env` are excluded from git via `.gitignore`
- `infra/setup.sh` applies `chmod 600` to all `*.env` files in this directory
- This directory is auto-discovered by `operational-backup.sh` for backup coverage

## Verification

```bash
# Confirm secrets are NOT tracked by git
git status auto-redeploy/secrets/

# Should show only: templates/, README.md, .gitkeep (tracked)
# discord.env and github.env should be untracked (gitignored)
```
