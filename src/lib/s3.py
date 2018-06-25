import os
import boto3
import botocore
from lib.logset import myLog
logger = myLog()


def get_s3_client():
    return boto3.client(service_name="s3", region_name=os.environ["AWS_REGION"], aws_access_key_id=os.environ["AWS_ACCESS_KEY"], aws_secret_access_key=os.environ["AWS_ACCESS_SECRET_KEY"])


def get_s3_resource():
    return boto3.resource(service_name="s3", region_name=os.environ["AWS_REGION"], aws_access_key_id=os.environ["AWS_ACCESS_KEY"], aws_secret_access_key=os.environ["AWS_ACCESS_SECRET_KEY"])


def upload_to_s3(filename, key):
    """
    Uploads the given file to the AWS S3 bucket and key (S3 filename) specified.

    Returns boolean indicating success/failure of upload.

    http://stackabuse.com/example-upload-a-file-to-aws-s3/
    """

    with open(filename, "r") as file:
        try:
            size = os.fstat(file.fileno()).st_size
        except:
            # Not all file objects implement fileno(),
            # so we fall back on this
            file.seek(0, os.SEEK_END)
            size = file.tell()

    # Uploads the given file using a managed uploader, which will split up large
    # files automatically and upload parts in parallel.
    get_s3_client().upload_file(filename, os.environ["AWS_BUCKET"], key)

    # Check the size of what we sent matches the size of what got there
    # s3 = boto3.resource("s3")
    object_summary = get_s3_resource().ObjectSummary(os.environ["AWS_BUCKET"], key)

    if object_summary.size != size:
        raise Exception("Failed uploading {} to S3 - size mismatch.".format(filename))
