# Maintenance

## PostgreSQL upgrades

The lazy "Eh, just dump everything and reload it rather than trying to upgrade it" approach.

1. Navigate to the shared logs directory `/etc/postgresql/pg_log`
2. Make it read-only with `ALTER DATABASE stack SET default_transaction_read_only=on;`
3. Dump the current database with `pg_dumpall -U postgres > dumpfile`
4. Stop the old container
5. Rename the old `data` directory
6. Start the new container
7. Import the dump into the new container with `psql -U postgres < dumpfile`
8. Follow any specific steps for this upgrade (e.g. the `PostgreSQL 10.7 to 15 upgrade` section below)
9. Make it non-read-only with `ALTER DATABASE stack SET default_transaction_read_only=off;`
10. ...
11. Profit!

### Template databases causing problems?

During this upgrade we had issues with dumping the template databases.

```
pg_dump: [archiver (db)] query failed: ERROR:  could not access file "$libdir/postgis-2.4": No such file or directory
pg_dump: [archiver (db)] query was: SELECT pg_catalog.pg_get_viewdef('17858'::pg_catalog.oid) AS viewdef
```

To resolve it, we ran `ALTER DATABASE [database_name] is_template FALSE;` before dropping the template databases.

### PostgreSQL 10.7 to 15 upgrade

Performed on 30 October, 2022.

Had to run through [these steps](https://www.crunchydata.com/blog/how-to-upgrade-postgresql-passwords-to-scram) to change the password authentication method being used.
