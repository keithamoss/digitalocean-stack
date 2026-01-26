# Backup Implementation Plan

## Overview

Application-level backup strategy for Raspberry Pi infrastructure with the following requirements:
- **Storage**: AWS S3 (Sydney region)
- **Budget**: AUD $5/month
- **Retention**: 30 daily backups, then 1/month thereafter
- **Logs**: Retain forever
- **Recovery**: PITR for PostgreSQL, point-in-time snapshots for Foundry
- **Monitoring**: Discord alerts (instant on failure, monthly heartbeat on success)

---

## Phase 1: Foundation & PostgreSQL Backups (CRITICAL)
**Goal**: Get database backups working with PITR before anything else

### Tasks:
1. **AWS S3 Setup**
   - [x] Create S3 bucket: `jig-ho-cottage-dr` (region: ap-southeast-2)
   - [x] Enable versioning (optional but recommended)
   - [x] Configure lifecycle policies:
     - 0-30 days: S3 Standard
     - 30-180 days: S3 Glacier Instant Retrieval
     - 180+ days: S3 Glacier Flexible Retrieval
   - [x] Create IAM user with minimal permissions (bucket access only)
   - [x] Store AWS credentials in `backups/secrets/aws.env`

2. **Install pgBackRest**
   - [x] Add pgBackRest installation to `infra/setup.sh`
   - [x] Install pgBackRest on Pi (via setup.sh or manually)
   - [x] Configure for PostgreSQL container
   - [x] Set up S3 repository: `s3://jig-ho-cottage-dr/pi-hosting/database/`
   - [x] Configure PostgreSQL for WAL archiving

3. **Initial Full Backup**
   - [x] Run first full backup manually
   - [x] Verify backup exists in S3
   - [x] Test restore to temporary container
   - [x] Document restore process

4. **Schedule Daily Backups**
   - [ ] Create systemd timer for 3am (database-backup.timer) ⚠️ NEXT STEP
   - [ ] Create systemd service (database-backup.service)
   - [ ] Configure retention (30 daily full backups, monthly thereafter)
   - [ ] Set up differential/incremental strategy
   - [ ] Enable and start timer

5. **Basic Monitoring**
   - [ ] Create backup status script
   - [ ] Configure Discord webhook
   - [ ] Set up failure notifications

### Validation Checklist:
- [ ] Backup runs successfully at 3am
- [ ] Can restore database from backup
- [ ] Discord alert works on failure
- [ ] WAL archiving is working
- [ ] Can perform point-in-time recovery

**Time estimate**: 2-3 hours work + testing over a few days

**Current Status (2026-01-26)**: Phase 1 in progress
- ✅ AWS S3 bucket and IAM setup complete
- ✅ pgBackRest installed and configured
- ✅ First full backup completed and verified in S3
- ✅ **Restore tested successfully** (1.4GB in 2.3 minutes)
- ✅ Restore procedures documented in [RESTORE.md](RESTORE.md)
- ⚠️ **NEXT**: Schedule daily backups with systemd timers

---

## Phase 2: Foundry Data Backups (VERY IMPORTANT)
**Goal**: Protect D&D campaign data

### Tasks:
1. **Install restic**
   - [ ] Install restic on Pi
   - [ ] Initialize S3 repository: `s3:s3.ap-southeast-2.amazonaws.com/jig-ho-cottage-dr/pi-hosting/foundry/`
   - [ ] Generate and store encryption key securely
   - [ ] Document encryption key location

2. **Configure Foundry Backup**
   - [ ] Create backup script for `foundry/data/`
   - [ ] Configure retention policy (30 daily, monthly thereafter)
   - [ ] Set S3 lifecycle policies (same as PostgreSQL)
   - [ ] Test deduplication is working

3. **Initial Backup & Test**
   - [ ] Run first backup manually
   - [ ] Verify backup in S3
   - [ ] Check storage size (should be ~current data size)
   - [ ] Test restore to temporary location
   - [ ] Run second backup and verify deduplication

4. **Schedule with PostgreSQL Backups**
   - [ ] Add to 3am backup routine
   - [ ] Ensure proper sequencing (DB first, then Foundry)
   - [ ] Handle errors gracefully

5. **Enhanced Monitoring**
   - [ ] Track backup sizes and durations
   - [ ] Add Foundry backups to Discord alerts
   - [ ] Monitor deduplication ratio

### Validation Checklist:
- [ ] Foundry data backed up daily at 3am
- [ ] Can list available snapshots
- [ ] Can restore specific snapshot
- [ ] Deduplication working (subsequent backups much smaller)
- [ ] Storage costs as expected (~under $1/month)

**Time estimate**: 1-2 hours work + testing

---

## Phase 3: Logs & Configuration (IMPORTANT)
**Goal**: Complete backup coverage

### Tasks:
0. **Logging Audit & Strategy** (Prerequisites)
   - [ ] Audit current logging setup across all services:
     - [ ] Which services are logging? (nginx, demsausage, foundry, redis, etc.)
     - [ ] Where are logs currently stored?
     - [ ] Are they using Docker logging drivers or file-based logs?
     - [ ] Check Docker Compose files for volume mounts and logging config
     - [ ] **Which services rotate logs vs. single growing files?**
   - [ ] Map all existing log locations:
     - [ ] `/logs/nginx/` (root repo level)
     - [ ] `demsausage/logs/`
     - [ ] `foundry/data/Logs/`
     - [ ] Docker container logs (check `docker logs` vs files)
     - [ ] Any other service-specific logs
   - [ ] **Implement log rotation where missing:**
     - [ ] Identify services with no rotation (single growing log files)
     - [ ] Choose rotation strategy:
       - Option A: `logrotate` (system-level, works for file-based logs)
       - Option B: Docker logging driver with rotation (json-file driver)
       - Option C: Application-level rotation (if supported)
     - [ ] Configure rotation policy (daily/weekly, keep N files, compression)
     - [ ] Test rotation is working
   - [ ] Decide on logging strategy:
     - [ ] Option A: Centralized in `/logs/` at repo root
     - [ ] Option B: Service-relative `logs/` folders
     - [ ] Consider: ease of backup, permissions, Docker volume management
   - [ ] Document current state and strategy decision
   - [ ] Update Docker Compose files if needed for consistency

1. **Logs Backup**
   - [ ] Initialize restic repository: `s3://jig-ho-cottage-dr/pi-hosting/logs/` (reuse encryption key from Foundry)
   - [ ] Create backup script for all log locations from step 0
   - [ ] Configure retention: keep all snapshots forever (no forget policy)
   - [ ] Test backup and snapshot listing
   - [ ] Add to 3am schedule

2. **Configuration Backup**
   - [ ] Initialize restic repository: `s3://jig-ho-cottage-dr/pi-hosting/configs/` (reuse encryption key)
   - [ ] Identify configs to backup (only non-git items):
     - [ ] **Secrets** (encrypted) - `backups/secrets/`, service-specific secrets
     - [ ] Any local modifications not in git
     - [ ] Generated/runtime configs not in version control
     - [ ] Note: Skip compose.yml, nginx configs, scripts - already in git
   - [ ] Create backup script
   - [ ] Encrypt secrets before backup (or rely on restic encryption)
   - [ ] Configure retention (30 daily, monthly thereafter)

3. **Consolidated Schedule**
   - [ ] Refactor backup orchestration
   - [ ] All backups coordinated at 3am
   - [ ] Proper error handling between phases
   - [ ] Summary report after all complete

### Validation Checklist:
- [ ] All log directories backing up
- [ ] Configs can be restored
- [ ] Secrets encrypted in backups
- [ ] Total S3 costs under budget
- [ ] Can identify and restore any backup component

**Time estimate**: 1-2 hours work

---

## Phase 4: Monitoring & Alerting (OPERATIONAL)
**Goal**: Know when things work or break

### Tasks:
1. **Discord Integration**
   - [ ] Configure webhook URL
   - [ ] Immediate failure alerts (any backup fails)
   - [ ] Daily summary (optional - decide if wanted)
   - [ ] Monthly "all healthy" heartbeat
   - [ ] Format messages with key metrics

2. **Backup Dashboard Script**
   - [ ] Create status check script
   - [ ] Report last backup dates for each component
   - [ ] Report backup sizes
   - [ ] Calculate and report estimated S3 costs
   - [ ] Show success rate over last 30 days

3. **Documentation**
   - [ ] Create `RESTORE.md` runbook
   - [ ] Document all backup locations
   - [ ] Document encryption key locations
   - [ ] Document recovery procedures for each component
   - [ ] Create quick-reference disaster recovery guide

### Validation Checklist:
- [ ] Receive Discord notifications on failure
- [ ] Monthly heartbeat working
- [ ] Can quickly assess backup health
- [ ] Have clear, tested restore procedures
- [ ] New team member could restore from docs

**Time estimate**: 1 hour work

---

## Phase 5: Automated Restore Testing (RELIABILITY)
**Goal**: Verify backups are actually restorable

### Tasks:
1. **PostgreSQL Restore Test**
   - [ ] Create test script
   - [ ] Spin up temporary PostgreSQL container
   - [ ] Restore latest backup
   - [ ] Run validation queries:
     - [ ] Table count matches
     - [ ] Row counts within expected ranges
     - [ ] Critical tables accessible
   - [ ] Clean up test container
   - [ ] Report results to Discord
   - [ ] Schedule monthly execution

2. **Foundry Restore Test**
   - [ ] Create test script
   - [ ] Restore latest snapshot to temp location
   - [ ] Verify file integrity
   - [ ] Check critical files exist
   - [ ] Compare checksums if available
   - [ ] Clean up temp files
   - [ ] Schedule monthly execution

3. **Restore Testing Dashboard**
   - [ ] Track test results over time
   - [ ] Store test history in simple log
   - [ ] Alert if test fails
   - [ ] Monthly summary of test results

### Validation Checklist:
- [ ] Monthly automated restore tests run
- [ ] PostgreSQL test successfully restores and validates
- [ ] Foundry test successfully restores and validates
- [ ] Alerts trigger if restore test fails
- [ ] High confidence in disaster recovery capability

**Time estimate**: 2-3 hours work

---

## Phase 6: Cost Optimization & Refinement (OPTIONAL)
**Goal**: Fine-tune for efficiency

### Tasks:
1. **Review Actual Costs**
   - [ ] Analyze first month of S3 bills
   - [ ] Break down costs by bucket
   - [ ] Adjust retention if needed
   - [ ] Optimize lifecycle policies based on actual usage

2. **Performance Tuning**
   - [ ] Benchmark backup times
   - [ ] Tune compression levels
   - [ ] Consider parallel operations
   - [ ] Add bandwidth throttling if needed
   - [ ] Optimize restic chunk size if needed

3. **Additional Features** (if desired)
   - [ ] Manual backup trigger before major changes
   - [ ] Pre-upgrade snapshot capability
   - [ ] Off-site copy to second cloud provider
   - [ ] Local backup copy on USB drive
   - [ ] Backup rotation visualization

---

## Timeline Summary

```
Week 1: Phase 1 (PostgreSQL) - CRITICAL
Week 2: Phase 2 (Foundry)     - VERY IMPORTANT  
Week 3: Phase 3 (Logs/Config) - IMPORTANT
Week 4: Phase 4 (Monitoring)  - OPERATIONAL
Week 5: Phase 5 (Testing)     - RELIABILITY
Week 6+: Phase 6 (Optimization) - OPTIONAL
```

**Minimum Viable Backup**: End of Phase 2
**Production Ready**: End of Phase 4
**Battle Tested**: End of Phase 5

---

## Cost Estimates

### Storage Breakdown (Monthly, Steady State):
- PostgreSQL backups: ~$0.50/month (1.6GB × 30 days + WAL + monthly archives)
- Foundry backups: ~$0.35/month (4GB with deduplication)
- Logs: ~$0.30/month (growing slowly)
- Configs: ~$0.05/month
- **Total: ~$1.20/month** ✅ Well under $5 budget

### Assumptions:
- PostgreSQL: 1.6GB database (actual size)
- Foundry: 4GB (actual size) - with deduplication will be very efficient
- Logs: ~1GB/month growth
- S3 pricing: ap-southeast-2 (Sydney)
- Lifecycle policies moving data to Glacier tiers after 30 days
- Logs: ~1GB/month growth
- S3 pricing: ap-southeast-2 (Sydney)
- Lifecycle policies moving to Glacier tiers

---

## Configuration Decisions

### S3 Bucket Structure:
**Single bucket**: `jig-ho-cottage-dr` (region: ap-southeast-2 Sydney)

**Prefix organization**:
```
jig-ho-cottage-dr/
├── pi-hosting/           # Primary Raspberry Pi infrastructure
│   ├── database/
│   ├── foundry/
│   ├── logs/
│   └── configs/
│
├── do-droplet/[name]/    # Temporary Digital Ocean droplets
│   ├── database/
│   └── logs/
│
├── do-managed/[name]/    # Temporary Digital Ocean managed databases
│   ├── database/
│   └── logs/
│
└── pi-home/              # Personal Raspberry Pi (Plex, etc.)
    ├── database/
    ├── plex/
    ├── logs/
    └── configs/
```

**Benefits**:
- Single bucket to manage and monitor
- Unified lifecycle policies
- Clear separation by infrastructure location
- Easy to add new infrastructure (new droplets, new Pis)
- Simpler IAM permissions

### Tools Selected:
- **PostgreSQL**: pgBackRest (full backups + PITR with WAL archiving)
- **Foundry**: restic (deduplication, encryption, snapshots)
- **Logs**: restic (snapshots, deduplication, handles rotation)
- **Configs**: restic (consistent with Foundry and logs)
- **Scheduling**: systemd timers
- **Monitoring**: Discord webhooks

### Encryption:
- **S3**: Server-side encryption (AWS SSE-S3)
- **restic**: Client-side encryption with passphrase
- **Secrets storage**: `backups/secrets/` directory
  - Never commit to git (add to .gitignore)
  - Store AWS credentials in `backups/secrets/aws.env`
  - Store restic password in `backups/secrets/restic.key`
  - Store Discord webhook in `backups/secrets/discord.env`
  - Template files in `backups/secrets/templates/`
  - **Best practice**: Also backup encrypted to password manager (1Password, Bitwarden, etc.)

### Backup Schedule:
- **Time**: 3am daily (all components)
- **Order**: PostgreSQL → Foundry → Logs → Configs
- **Retention**: 30 daily backups, then 1/month

---

## Notes & Decisions Log

### 2026-01-26: Initial Planning & Phase 1 Progress
- Decided on application-level backups over full disk imaging
- Confirmed ext4 filesystem (no LVM/BTRFS snapshots available)
- Selected Sydney region for S3
- Confirmed budget of AUD $5/month
- PostgreSQL identified as most critical component
- Redis confirmed as ephemeral (no backup needed)
- Nginx content rebuilds from GitHub Actions (no backup needed)
- **PostgreSQL container**: `db` running `ghcr.io/baosystems/postgis:15-3.3`
- **Actual DB size**: 1.6GB (much smaller than estimated)
- **Foundry data size**: ~4GB (confirmed)
- **Recovery objectives**: RTO 2 hours, RPO 30 minutes
  - RPO of 30 mins requires WAL archiving (PITR) - validates our approach
- **Discord webhook**: Configured and ready
- **Implementation start**: 2026-01-26 (today)
- **S3 bucket structure**: Single bucket `jig-ho-cottage-dr` with organized prefixes
  - Supports multiple infrastructure locations (pi-hosting, do-droplet, pi-home)
  - Simplifies management and lifecycle policies
  - Future-proof for adding new infrastructure

**Phase 1 Implementation Progress**:
- ✅ AWS S3 bucket `jig-ho-cottage-dr` created in ap-southeast-2
- ✅ IAM user created with bucket-only permissions
- ✅ pgBackRest installed and configured on Pi
- ✅ PostgreSQL configured for WAL archiving
- ✅ First full backup completed successfully
- ✅ Backup verified in S3 at `pi-hosting/database/`
- ✅ **Restore tested**: 1.4GB restored in 138 seconds (4,970 files)
- ✅ Restore procedures documented in RESTORE.md
- ⚠️ **Next**: Systemd timers for daily automated backups

---

## Questions & Clarifications Needed

### Answered:
1. ✅ S3 bucket naming: `stack-*-syd` (supports Pi + DO droplet)
2. ✅ Discord webhook: Configured (see secrets)
3. ✅ PostgreSQL size: 1.6GB
4. ✅ Start date: 2026-01-26 (today)
5. ✅ Secrets storage: `backups/secrets/` directory (see below)
6. ✅ RTO: 2 hours maximum
7. ✅ RPO: 30 minutes maximum (requires PITR)

### Still needed:
1. ✅ Foundry data size: ~4GB (confirmed via du -sh)
2. ✅ AWS IAM credentials: Created and configured

**All planning questions answered - ready to begin implementation!**

---

## Success Criteria

### Phase 1 Success:
- Daily PostgreSQL backups running
- PITR capability verified
- Can restore to any point in last 30 days

### Overall Success:
- All critical data backed up daily
- Restore tested monthly
- Costs under budget
- Zero data loss in DR scenario
- Recovery time under 1 hour for critical systems
