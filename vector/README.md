# Vector Log Shipper (Staging)

This directory contains configuration for Vector to tail local Django and NGINX logs and batch/compress them to S3.

## Files
- `vector.yaml`: Active config mounted into the container at `/etc/vector/vector.yaml`

## Required Environment Variables
- `AWS_REGION`: AWS region hosting the S3 bucket (e.g. `ap-southeast-2`).
- `VECTOR_S3_BUCKET`: Name of the S3 bucket receiving logs (no `s3://` prefix).
- AWS Credentials (one of):
  - `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN` if using STS), OR
  - Instance / container role (preferred in production), OR
  - Injected via an `env_file` mounted to the service.

## Optional Environment Variables
- `AWS_ENDPOINT_URL`: Use with alternative S3-compatible storage (MinIO, etc.).
- `VECTOR_LOG`: Adjust internal logging level (e.g. `info`, `debug`).

## IAM Minimum Policy Snippet
Grant only put capabilities to the log prefixes used:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::YOUR_BUCKET/demsausage/django/*",
        "arn:aws:s3:::YOUR_BUCKET/demsausage/nginx/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::YOUR_BUCKET"
    }
  ]
}
```
Replace `YOUR_BUCKET` with the actual bucket name.

## Rotation vs Streaming
Vector streams log lines directly; historical weekly rotation is replaced by continuous batching. For long-term retention or cost control, configure S3 lifecycle rules (e.g. transition to Glacier after 90 days, expire after 365 days).

## Updating Vector Version
Image pinned at `timberio/vector:0.51.1-alpine`. Periodically:
1. Review release notes.
2. Pull new tag locally: `docker pull timberio/vector:0.52.0-alpine` (or latest stable).
3. Obtain digest: `docker inspect --format='{{index .RepoDigests 0}}' timberio/vector:0.52.0-alpine` and update compose to use `tag@sha256:digest` for supply-chain integrity.

Recent change applied: replaced deprecated `default_region` with `region` field in S3 sinks and enabled an NGINX VRL parsing transform for structured output.

## Configuration Loading
Vector by default searches for `/etc/vector/vector.yaml` (and supports TOML/YAML/JSON/HCL). We mount `vector.toml` at that path:
```
./vector/vector.toml:/etc/vector/vector.yaml:ro
```
If you prefer explicit flags, you can instead use:
```
command: ["/usr/bin/vector", "--config", "/etc/vector/vector.toml"]
```
or set an environment variable:
```
VECTOR_CONFIG=/etc/vector/vector.toml
```
Only one is needed; current approach keeps compose simple.

## Metrics
Prometheus exporter exposed on port `9090`. Example scrape config:
```yaml
- job_name: 'vector-staging'
  static_configs:
    - targets: ['logshipper:9090']
```

## Future Enhancements
- Enable VRL transforms for NGINX parsing (status codes, latency buckets).
- Add disk buffering for durability: set `data_dir.path` and configure sinks with `buffer.max_size`.
- Add CloudWatch or Loki sinks for querying capabilities.

## Troubleshooting
- No uploads? Check credentials and bucket name; enable `VECTOR_LOG=debug`.
- High memory usage? Reduce `batch.max_events` or increase flush frequency.
- Duplicate lines? Ensure `read_from = "end"` is set initially to avoid replay of historical logs.
- Objects look uncompressed? AWS CLI auto-decompresses when `ContentEncoding=gzip`. Use `aws s3api get-object` or set `AWS_NO_DECOMPRESSION=1` when downloading to inspect raw gzipped bytes (look for magic header `1f8b`).
