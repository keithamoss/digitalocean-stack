# Foundry patch checklist

- Create a snapshot first to backup the game, module, and world state
- Bump the image tag in [foundry/compose.yml](compose.yml) for the new release.
- From the repo root, run `sudo ./orchestration/foundry.sh` to pull, stop, and restart Foundry.
- Tail logs if needed: `docker compose -f foundry/compose.yml logs foundry --follow`.
- In the UI: 
  - Accept the software license (if prompted)
  - Update all game systems/addons, and
  - Lanch each game world to trigger migrations