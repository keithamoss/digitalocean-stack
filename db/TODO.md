# MVP
1. Spin up DO Droplet and Managed Database
1.1. Setup Droplet with this repo
2. Testing with staging
2.1 Setup secrets
2.2 Migrate staging database (RENAME_SOURCE=false)
2.3 Publish and spin up app
2.4 Repoint staging DNS to DO
2.5 Verify staging works
2.6 Unpublish, spin down, and repoint staging DNS back to Pi
3. Shifting production to DO
3.1 Setup secrets
3.2 Migrate production database (RENAME_SOURCE=false)
3.3 Publish and spin up app
3.4 Repoint DNS to DO
3.5 Verify production works
3.6 Wait for DNS changes to propagate completely
3.7 Unpublish and spin down the Pi app
3.8 Rename the database on the Pi
4. Shifting production to Pi
4.1 Migrate production database (RENAME_SOURCE=false)
4.2 Publish and spin up app
4.3 Repoint DNS to Pi
4.4 Verify production works
4.5 Wait for DNS changes to propagate completely
4.6 Unpublish and spin down the DO app
4.7 Destroy the DO Droplet and Managed Database

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