import os
import time
from lib.logset import myLog
from lib.digitalocean import Deploy
logger = myLog()

os.environ["TZ"] = "Australia/Perth"
time.tzset()

DIGITALOCEAN_TOKEN = os.environ["DIGITALOCEAN_TOKEN"]
GITHUB_PERSONAL_ACCESS_TOKEN = os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"]
SNAPSHOT_NAME = "stack-a-v1-docker-17.12-ubuntu-16.04-s-1vcpu-1gb-sgp1-01"
FLOATING_IP = "167.99.31.197"
Deploy(DIGITALOCEAN_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN, SNAPSHOT_NAME, FLOATING_IP)

# So Travis-CI will notify us of issues
if logger.has_critical_or_errors():
    print("We've got a few errors:")
    print(logger.status())
    exit(1)
