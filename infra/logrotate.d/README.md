# Logrotate Configurations

This directory contains logrotate configuration files for the Raspberry Pi hosting infrastructure.

## Files

- **nginx** - Log rotation for nginx access and error logs
- **demsausage** - Log rotation for demsausage application logs (gunicorn, RQ workers, django, supervisord, cron)

## Deployment

To deploy all logrotate configs to /etc/logrotate.d/:

```sh
sudo ./infra/deploy-logrotate.sh
```

This will copy all configs in this directory to /etc/logrotate.d/ with the correct names and permissions.

## Log Rotation Format

All rotated logs use the format: `[name]-YYYY.MM.DD.log`

Examples:
- `access-2026.01.27.log`
- `django-2026.01.27.log`
- `gunicorn_a-2026.01.27.log`

## Retention

- **Daily rotation**: Logs are rotated once per day (via system cron)
- **Retention**: 60 days
- **Compression**: Enabled (delayed by 1 day)

## Testing

Test a configuration manually:
```bash
# Dry run (shows what would happen)
sudo logrotate -d /etc/logrotate.d/digitalocean-stack-nginx

# Force rotation (actually rotates)
sudo logrotate -f /etc/logrotate.d/digitalocean-stack-nginx
```

## Making Changes

1. Edit the config file in this directory ([infra/logrotate.d/](./))
2. Commit and push to git
3. Re-run [infra/setup.sh](../setup.sh) to deploy, or manually copy:
   ```bash
   sudo cp infra/logrotate.d/nginx /etc/logrotate.d/digitalocean-stack-nginx
   ```
