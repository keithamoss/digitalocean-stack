# Secrets Directory

This directory stores sensitive credentials used by backup scripts.

## Files to Create

Copy templates from `templates/` subdirectory and fill in actual values:

### 1. AWS Credentials
**File**: `aws.env`  
**Template**: `templates/aws.env`  
**Used by**: pgBackRest, restic (all backup operations)

```bash
cp templates/aws.env aws.env
# Then edit aws.env with your actual credentials
```

### 2. Restic Encryption Key (Phase 2)
**File**: `restic.key`  
**Created during**: Phase 2 (Foundry backups)  
**Used by**: restic (Foundry, logs, configs backups)

Will be generated automatically during restic repository initialization.

### 3. Discord Webhook (Phase 4)
**File**: `discord.env`  
**Template**: Will be created in Phase 4  
**Used by**: Backup monitoring scripts

## Security Best Practices

1. **Never commit secrets to git**
   - `.gitignore` already covers `**/secrets/*.env`
   - Double-check with `git status` before committing

2. **Backup credentials elsewhere**
   - Store in password manager (1Password, Bitwarden, etc.)
   - Keep encrypted backup on separate system

3. **Restrict file permissions**
   ```bash
   chmod 600 *.env
   chmod 600 *.key
   ```

4. **Rotate credentials regularly**
   - AWS access keys: every 90 days
   - Document rotation in calendar

## Current State

- [x] Directory structure created
- [ ] `aws.env` - Fill in AWS credentials
- [ ] `restic.key` - Will be generated in Phase 2
- [ ] `discord.env` - Will be created in Phase 4

## Verification

```bash
# Check that secrets are NOT tracked by git
git status backups/secrets/

# Should only show untracked files or changes to:
# - README.md
# - .gitkeep  
# - templates/

# Verify permissions
ls -la backups/secrets/
```
