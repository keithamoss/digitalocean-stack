# Backup Monitoring Setup

This directory contains monitoring scripts for the backup system.

## Files

### Scripts
- **backup-status.sh** - Main status monitoring script
  - `./backup-status.sh status` - Display detailed backup status
  - `./backup-status.sh heartbeat` - Send daily health check to Discord
  
- **send-failure-alert.sh** - Called by systemd on backup failures
- **discord-lib.sh** - Shared Discord notification library

### Systemd Services
- **postgres-backup-heartbeat.service** - Systemd service for daily heartbeat
- **postgres-backup-heartbeat.timer** - Timer for daily heartbeat at 3:30 AM

## Setup

1. **Configure Discord webhook:**
   ```bash
   cp secrets/templates/discord.env secrets/discord.env
   # Edit secrets/discord.env and add your Discord webhook URL
   ```

2. **Install systemd timer for daily heartbeat:**
   ```bash
   cd systemd
   sudo ./install.sh
   ```
   This will also update the backup services with failure alerting.

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
- **Daily heartbeat** (3:30 AM): Health status with key metrics
- **Warnings**: Stale backups (>36 hours old)

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
- Check timer is enabled: `systemctl status postgres-backup-heartbeat.timer`
- View logs: `journalctl -u postgres-backup-heartbeat.service`

## Dependencies

- `jq` - JSON parsing (install: `sudo apt install jq`)
- `curl` - Discord webhooks
- `docker` - Access to db container
- `date` - Timestamp parsing
