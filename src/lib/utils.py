import hashlib
from lib.logset import myLog
logger = myLog()


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
