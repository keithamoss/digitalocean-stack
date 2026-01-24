# MVP
0. Spin up cloud-based app server [DONE]
1. Spin up cloud-based apps using Pi database [DONE]
2. Spin up managed database service [DONE]
3. Stop writes, allow transactions to finalise [DONE]
4. Dump backup [DONE]
5. Restore backup [DONE]
6. Repoint DNS
7. (Maybe?) Bounce self-hosted apps to force reconnect

# Migration: DO PostgreSQL's logs
There's no way to download them via the UI or CLI. The only option is to forward them to a log service.

All too hard at the moment, so leaving it for another day.

# Separating DBs
There's less admin to do if all we're doing is pushing DemSausage PROD's database to the cloud - not the whole database, not all PROD applications. But that means restructuring it all and updating all of ours apps.

If we do this, we need to tweak our DNS so there's a standalone e.g. demsausage-prod.db.keithmoss.me alongside e.g. db.keithmoss.me used for everything else

In doing this, we also need to change to use the same port on the Pi's database as DO (25060).

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