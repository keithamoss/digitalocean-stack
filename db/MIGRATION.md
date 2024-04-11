# Migrating the database from Digital Ocean to AWS

## Setting up the Projects Database EC2

Create a new Ubuntu EC2 (https://docs.docker.com/engine/install/ubuntu/)

Create a PEM file (@TODO document) and save it locally to `~/.ssh/aws-macbook.pem`.

Setup an SSH alias to make life easier:

```
Host aws-db
  Hostname IPV4 DNS Hostname
  User ubuntu
  IdentityFile /Users/keithmoss/.ssh/aws-macbook.pem
```

Clone the stack repo:

```
git clone https://github.com/keithamoss/digitalocean-stack.git

cd digitalocean-stack

cd db

mkdir logs

chmod 777 logs

chmod 777 redis
```

Setup secrets `.env` files:

```
mkdir secrets

Create secrets:

- db.env
- pgbackups3-[env].env
- redis.env
```

Now bring the database up!

```
sudo ./redeploy.sh
```

## Setting up the CloudWatch agent

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html](Install the CloudWatch Agent):

```
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb

sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
```

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-cloudwatch-agent-configuration-file.html](Configure the CloudWatch Agent):

```
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-config-wizard
```

Store the resulting JSON config file (`/opt/aws/amazon-cloudwatch-agent/bin/config.json`) somewhere locally for safe keeping.

[https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/create-iam-roles-for-cloudwatch-agent-commandline.html](Create an IAM role for the CloudWatch Agent):

- Create an IAM role as directed e.g. `CloudWatchAgentProjectsDBServerRole`
- Attach the IAM role to the instance

Start up the agent:

```
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
```

To confirm the agent's status:

```
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status
```

Installing SSM (for maybe auto-patching later, but for now remote querying it via Systems Manager):

[https://docs.aws.amazon.com/systems-manager/latest/userguide/managed-instances-default-host-management](Using the Default Host Management Configuration setting)

Ran through the Systems Manager 'Quick setup' process for 'Host management'

<damnit, this lets us setup the CloudWatch agent on the EC2 instances>

@TODO Redo the instructions to skip that step when we CDK-ise it

Chose to update (but not install, as we did that manually) the CloudWatch agent

Chose to update the EC2 Launch Agent too

Applied to just the 'Current account' and 'Current region' to 'All instances'

It took about 15 minutes, but the instance eventually appeared in Fleet manager and we could run the CloudWatch status command on it and confirm that it was seen to be running from outside.

## Migrating the database from DigitalOcean to AWS

SSH into the DigitalOcean database (`db-a`) and hop into the PostgreSQL container:

`docker compose -f db-production.yml exec -it db /bin/bash`

Make all databases read-only:

```sql
ALTER DATABASE dbname SET default_transaction_read_only=on;
```

As a precaution, we can always just shut the database down too:

```
docker compose -f db-production.yml stop
```

Now dump out the relevant databases:

```
pg_dump --username=postgres --format=custom stack --file=pg_dump_stack

pg_dump --username=postgres --format=custom staging --file=pg_dump_staging
```

Exit out of the PostgreSQL containers and copy the dump files out into `db-a` itself:

```
docker compose -f db-production.yml cp db:/pg_dump_stack ./pg_dump_stack
docker compose -f db-production.yml cp db:/pg_dump_staging ./pg_dump_staging
```

Now, from macOS-land we can pipe the files across from `db-a` to `aws-db`:

```
scp db-a:/apps/digitalocean-stack/db/pg_dump_stack aws-db:/home/ubuntu/digitalocean-stack/db/pg_dump_stack
scp db-a:/apps/digitalocean-stack/db/pg_dump_staging aws-db:/home/ubuntu/digitalocean-stack/db/pg_dump_staging
```

Now SSH into the EC2 on AWS (`aws-db`).

If we've played around a bit with the database, we best purge it:

```
sudo docker compose -f db-production.yml stop
sudo rm -r postgres-data
sudo redeploy.sh
```

Now copy the pg_dump files into the running PostgreSQL container:

```
sudo docker compose -f db-production.yml cp pg_dump_stack db:/pg_dump_stack
sudo docker compose -f db-production.yml cp pg_dump_staging db:/pg_dump_staging
```

Connect via Postico (or a DB client of your choice) and create empty databases for each of the databases we're restoring:

```sql
CREATE DATABASE stack;
CREATE DATABASE staging;
```

Now we can load the pg_dump files:

```
sudo docker compose -f db-production.yml exec -it db /bin/bash

pg_restore --username=postgres --verbose --clean --format=custom --dbname=stack pg_dump_stack > pg_restore_stack.log
pg_restore --username=postgres --verbose --clean --format=custom --dbname=staging pg_dump_staging > pg_restore_staging.log
```

Note: this will spew warnings/errors about schemas not existing for this and that, but it seems we can safely ignore those.

Now, since as part of this migration we want to rename `stack` to `production`, we need to terminate any open connections and rename:

```sql
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = 'stack';

ALTER DATABASE stack RENAME to production;
```

Now we can make the new database read-write again:

```
ALTER DATABASE dbname SET default_transaction_read_only=off;
```

Now, lastly, we just need to update our secrets files with the new connection details and new database names:

Change the connection details for the DO droplets and bounce each one:

- mapa.keithmoss.me: mapa-db.env
- demsausage-production: rq-dashboard.env, sausage-db.env, sausage-web.env
- demsausage-staging: sausage-db.env (note: redis here is run locally)

We also need to change the DB management scripts in each repo.

Also update the secrets in AWS Secrets Manager for any running services that need the new connection details.

And as part of clean-up, don't forget to go and `rm` the pg_dump files from everywhere.

If you like, this is also a good time to test that the pgbackups3 service works:

sudo docker compose -f db-production.yml exec pgbackups3-prod sh backup.sh
sudo docker compose -f db-production.yml exec pgbackups3-staging sh backup.sh

## Populating Mapa's staging database from prod

```
docker compose -f db-production.yml exec -it db /bin/bash

pg_dump --username=postgres --format=custom production --schema=mapa --file=pg_dump_production_mapa

pg_restore --username=postgres --verbose --clean --format=custom --dbname=staging --schema=mapa pg_dump_production_mapa
```

## Archiving the Scremsong schema

SSH into `db-a`:

```
docker compose -f db-production.yml exec -it db /bin/bash

pg_dump --username=postgres --format=custom stack --schema=scremsong --file=pg_dump_production_scremsong
```

Exit the PostgreSQL container and:

```
docker compose -f db-production.yml cp db:/pg_dump_production_scremsong ./pg_dump_production_scremsong
```

From macOS:

```
scp db-a:/apps/digitalocean-stack/db/pg_dump_production_scremsong /Users/keithmoss/Downloads/pg_dump_production_scremsong
```

Now archive the pg_dump file in S3:

Lastly, we can finally drop the schema:

```sql
DROP SCHEMA scremsong CASCADE;
```

And as part of clean-up, don't forget to go and `rm` the pg_dump file from everywhere.