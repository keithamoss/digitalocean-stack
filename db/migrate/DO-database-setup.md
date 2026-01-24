# DigitalOcean Database Setup

## Cluster Configuration

**Databases** → **Create Database Cluster**

- **Engine**: PostgreSQL 15
- **Region**: Sydney (SYD1)
- **Plan**: Basic Shared CPU Plans - Premium AMD
  - **Initial warmup**: 2 vCPU / 4GB RAM (scale up after migration complete)
  - **Production**: 14 vCPU / 16GB RAM (upgrade once stable)
- **Nodes**: 1 node (single-node, no HA during initial period)

## Network & Security

- **Trusted Sources**: Restrict to home IP address only
- **VPC**: Not required for initial setup (single source access)
- **SSL**: Enforced by default (`sslmode=require`)
- **Maintenance Window**: Saturday 1:00 AM AEDT

## Connection Details

Post-provisioning, note:
```
Host: db-postgresql-xxx.ondigitalocean.com
Port: 25060 (not 5432)
User: doadmin
Database: defaultdb
```

## Migration Script Config

Update `migrate_*.env`:

```bash
TARGET_HOST="db-postgresql-xxx.ondigitalocean.com"
TARGET_PORT="25060"
TARGET_USER="doadmin"
TARGET_PASS="generated_password"
TARGET_SSLMODE="require"
TARGET_ADMIN_DB="defaultdb"
TARGET_APP_ROLE="app_user"
TARGET_APP_ROLE_PASSWORD="app_password"
```

## Important Notes

- **Connection pooling**: DO databases have connection limits; use PgBouncer for production
- **Backups**: Automated daily backups enabled by default; retention configurable in Settings
- **Storage**: Auto-scales when 95% full (increases cost); monitor in metrics dashboard
- **Maintenance windows**: Configured automatically; can be adjusted in Settings
- **Certificate pinning**: Connection certs rotate; don't pin, use system CA bundle
- **Reserved pricing**: Available for 1-3 year terms if running production long-term

## Gotchas

- Default `doadmin` user has superuser privileges; migration script creates `TARGET_APP_ROLE` with limited privileges
- Port is 25060, not standard 5432
- Connection string format: `postgres://user:pass@host:25060/db?sslmode=require`
- Max connections limited by plan tier; check "Current Plan" for limits

