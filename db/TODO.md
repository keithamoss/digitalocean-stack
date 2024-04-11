# Migrating the Projects Database from Click Ops to CDK

Including fun things like looking at AWS Backup of EBS volumes to replace DigitalOcean snapshotting. Or, you know, if there's an even easier in-built way to tell EBS volumes to snapshot themselves periodically.

- Ref https://docs.aws.amazon.com/prescriptive-guidance/latest/backup-recovery/new-ebs-volume-backups.html for best practice on the process for databases
- Use CDK to setup CloudWatch alarms mirroring what DO gave us (depending on cost) (https://marbot.io/blog/monitoring-ec2-disk-usage.html)
- Use CDK to setup snapshots mirroring what DO gave us (depending on cost)
- Auto-patching via Systems Manager
- What's the minimum permission levels for the PostgreSQL logs directory? (currently 777)