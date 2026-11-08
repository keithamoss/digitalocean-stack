# Backup Monitoring Setup

This directory contains monitoring scripts for the backup system.

## Files

### Scripts
- **backup-status.sh** - Main status monitoring script
  - `./backup-status.sh status` - Display detailed backup status
  - `./backup-status.sh heartbeat` - Send daily health check to Discord

- **check-restore-test.sh** - Restore-test dashboard checker
   - Parses latest restore orchestration log (`logs/restore/orchestration/restore-test-*.log`)
   - Exposes result/age/status to `backup-status.sh` (including stale warning threshold)
  
- **send-failure-alert.sh** - Called by systemd on backup failures
- **discord-lib.sh** - Shared Discord notification library

### Systemd Services
- **consolidated-backup.service** - Runs the full backup sequence in order
- **consolidated-backup.timer** - Triggers the backup sequence daily at 3:00 AM
- **backup-heartbeat.service** - Sends final summary/health message after orchestration

## Setup

1. **Configure Discord webhook:**
   ```bash
   cp secrets/templates/discord.env secrets/discord.env
   # Edit secrets/discord.env and add your Discord webhook URL
   ```

2. **Install systemd units and timers:**
   ```bash
   cd /home/keith/digitalocean-stack/backups
   sudo ./install-systemd.sh
   ```
   This installs and enables consolidated backup orchestration, heartbeat integration, and failure alerting.

3. **Test the status script:**
   ```bash
   ./backup-status.sh status
   ```

4. **Test Discord heartbeat:**
   ```bash
   ./backup-status.sh heartbeat
   ```

## Features

### Status Check
- Container health
- Last full/differential backup times
- Backup sizes and counts
- WAL archiving status
- PITR recovery range
- Backup age warnings

### Discord Alerts
- **Failure alerts** (immediate): Sent when backups fail
- **Daily heartbeat** (end of consolidated run): Sent after all phases complete, Discord messages sent only on:
  - **Weekends** (Saturday/Sunday): Health status with key metrics
  - **Warnings or Errors** (any day): Issues requiring attention
- **Warnings**: Stale backups (>36 hours old)
  - Heartbeat exit code `1` means warnings were reported, not that a backup failed.
    The heartbeat service accepts this code via `SuccessExitStatus=1`, preventing
    an additional generic failure alert. Critical errors (code `2`) and runtime
    failures still trigger `OnFailure`. Unexpected heartbeat exits, including
    missing dependencies/configuration and fatal shell errors, are normalized
    to code `2`; only the completed health assessment can return warning code `1`.

### S3 Cost Reports
- `costs/s3-cost-report.sh` scans explicit pages of up to 1,000 S3 objects,
  aggregating per-storage-class totals without passing object lists as CLI arguments.
- Listing/parsing errors, invalid pagination, and the 200-page safety limit abort
  the report rather than publish partial or zero-cost results.
- Monthly JSON state is written to a temporary file and atomically renamed.
  The latest-state symlink is also atomically replaced before a success notification.
  `--no-save-state` still allows a console/Discord report without updating state.
- A report older than 32 days produces a heartbeat warning. Fix the report job
  rather than increasing that threshold.
- After remediation, run:
  ```bash
  sudo systemctl start s3-cost-report.service
  sudo systemctl start backup-heartbeat.service
  ```
- Regression checks (isolated fixtures; no AWS or Discord requests):
  ```bash
  bash tests/backup-monitoring-test.sh
  ```

### Output Examples

**Console:**
```
=== PostgreSQL Backup Status ===

✓ Container: db is running
✓ Total backups: 8

Last Full Backup:    2026-01-26 03:00:15 (20260126-030015F)
Last Differential:   2026-01-27 03:00:45 (20260127-030045D)

Latest Backup:       2026-01-27 03:00:45 (diff)
Backup Size:         1GB
Delta Size:          45MB
Latest WAL Archive:  000000010000000000000042

PITR Recovery Range:
  From: 2026-01-20 03:00:10
  To:   2026-01-27 03:00:45

S3 Repository:       OK (stanza: main)

✓ Backup system operational
```

**Discord (Healthy):**
```
✅ Backup System Healthy

PostgreSQL Backup Status

✓ System: `pi-hosting`
✓ Total backups: `8`
✓ Last backup: `2026-01-27 03:00:45` (12h ago)
✓ Type: `diff`
✓ Size: `1GB`
✓ PITR Range: `2026-01-20 03:00` → `2026-01-27 03:00`
✓ WAL Archive: Active
✓ S3 Repo: Operational

All systems nominal.
```

**Discord (Failure):**
```
🚨 Backup Failed

PostgreSQL Differential Backup Failed

System: `raspberrypi`
Exit Code: `1`
Time: 2026-01-27 03:00:45

Action Required: Check logs with:
journalctl -u postgres-*-backup.service -n 50
```

## Troubleshooting

### No Discord notifications
- Check `secrets/discord.env` exists and has valid webhook URL
- Test webhook manually: `curl -X POST $DISCORD_WEBHOOK_URL -H "Content-Type: application/json" -d '{"content":"test"}'`

### Script fails
- Ensure Docker container `db` is running: `docker ps`
- Check pgBackRest is installed: `docker exec db which pgbackrest`
- Check jq is installed: `which jq`

### Heartbeat not running
- Check orchestration timer is enabled: `systemctl status consolidated-backup.timer`
- Check heartbeat service logs: `journalctl -u backup-heartbeat.service -n 100`
- Check full run logs: `journalctl -u consolidated-backup.service -n 200`

## Dependencies

- `jq` - JSON parsing (install: `sudo apt install jq`)
- `curl` - Discord webhooks
- `docker` - Access to db container
- `date` - Timestamp parsing
