# Demsausage Staging Publish/Unpublish Workflow

To control whether local nginx proxies to the demsausage staging services:

## Publish (enable local proxy)

    ./publish.sh

This creates a directory symlink to the configs and reloads nginx via `orchestration/nginx.sh` (downloads artifacts). If the symlink already exists and points to the right place, it skips the reload.

## Unpublish (disable local proxy)

    ./unpublish.sh

This removes the directory symlink and reloads nginx via `orchestration/nginx.sh --skip-download` (no artifact download). If the symlink is absent, it skips the reload.

## Notes
- The configs live under `demsausage/nginx/conf.d/` and are exposed via a directory symlink at `nginx/conf.d/demsausage` (directory-level symlink).
- Publish reloads via `orchestration/nginx.sh` (with artifact download); unpublish reloads via `orchestration/nginx.sh --skip-download`.
- Use this workflow when moving staging services between hosts to avoid double proxying.
