import os
import subprocess
# import lib.utils

import hashlib


def md5_hash_file(filename):
    """
    Thanks https://stackoverflow.com/a/22058673
    """

    BUF_SIZE = 5120000  # 5MB chunks for now to avoid potential memory issues

    md5 = hashlib.md5()

    with open(filename, "rb") as f:
        while True:
            data = f.read(BUF_SIZE)
            if not data:
                break
            md5.update(data)

    return md5.hexdigest()

# a = os.makedirs("/var/tmp/backup-db/tmp/", exist_ok=True)
# print(a)

# f = subprocess.check_output(["pwd"])
# print(f)

# subprocess.check_output(["cd", "/var/tmp/backup-db"])


subprocess.check_output("docker exec -it db_db_1 pg_dump -U postgres --format=c --file=postgres.sqlc postgres".split(" "))
subprocess.check_output("docker cp db_db_1:/postgres.sqlc ./tmp/postgres.sqlc".split(" "))

subprocess.check_output("docker exec -it db_db_1 pg_dumpall -g -Upostgres --file=globals.sql;".split(" "))
subprocess.check_output("docker cp db_db_1:/globals.sql ./tmp/globals.sql".split(" "))

subprocess.check_output("tar -zcvf db.tar tmp/".split(" "))

print(md5_hash_file("db.tar"))
