# How will we achieve...

- Disk backup snapshots / some other backup strategy (think: DR)
- Pi usage monitoring and alerting (see that /r/selfhosting tab open on my phone)
- Deploy to / from cloud
- Logs

# Logs
Map out all of the log sources we want to stream (e.g. including Cloudflared)

Revisit the Vector logshipper and have it write non-raw NGinx and Django logs and other improvements sugested by Copilot

# GitHub Actions redeploying stacks
SSH in as MVP is easiest and is consistent with the approach used for the cloud stack. Can we use CloudFlare tunnels to make getting in safer?

# Docker volume mounts: Cached vs delegated
https://tkacz.pro/docker-volumes-cached-vs-delegated/