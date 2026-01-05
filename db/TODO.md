# MVP
0. Spin up cloud-based app server
1. Spin up managed database service
2. Stop writes, allow transactions to finalise
3. Dump backup
4. Restore backup
5. Repoint DNS
6. Spin up cloud-based apps
7. (Maybe?) Bounce self-hosted apps to force reconnect

# Image change
Changed PostgreSQL/PostGIS image because the official images are all AMD-based, not ARM

Did I then have to run this on the Pi?

```
sudo chown -R 999:999 ./logs
sudo chmod 700 ./logs
```

# Password change
Had to run this to change the password to one without special chars because something didn't like it (and it had caused problems in the past anyway)

ALTER USER postgres WITH PASSWORD 'NEW PASSWORD WITHOUT SPECIAL CHARS';

# Tune postgresql.conf for our Pi and it's hardware

# Upgrade
Let's check if everything is ready to go to v18 yet

# Support connection ONLY over SSL