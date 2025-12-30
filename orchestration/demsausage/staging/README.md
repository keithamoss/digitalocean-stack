# Demsausage Staging Publish/Unpublish Workflow

To control whether local nginx proxies to the demsausage staging services:

## Publish (enable local proxy)

    ./publish.sh

This copies the configs into `nginx/conf.d/demsausage` and reloads nginx via `orchestration/nginx.sh` (downloads artifacts). If nothing changes, it skips the reload.

## Unpublish (disable local proxy)

    ./unpublish.sh

This removes the copied configs and reloads nginx via `orchestration/nginx.sh --skip-download` (no artifact download). If nothing was published, it skips the reload.

## Notes
- The configs live under `demsausage/nginx/conf.d/` and are copied into `nginx/conf.d/demsausage` for nginx to load (no symlinks).
- Publish reloads via `orchestration/nginx.sh` (with artifact download); unpublish reloads via `orchestration/nginx.sh --skip-download`.
- Use this workflow when moving staging services between hosts to avoid double proxying.
