#!/usr/bin/env bash

set -euo pipefail

# Reindex-from-Snapshot macOS wrapper
# - Uses official Docker image to avoid local Java/Gradle install
# - Mounts user-writable temp dirs to avoid macOS SIP-protected paths
# - Loops until the worker exits with code 3 (NoWorkLeft)
# - Supports basic auth via flags and env (TARGET_USERNAME/TARGET_PASSWORD)

usage() {
  cat <<'USAGE'
Usage:
  ./reindex-from-snapshot-macos.sh \
    --snapshot-name SNAP \
    --s3-repo-uri s3://bucket/prefix \
    --s3-region us-east-1 \
    --target-host https://your-target-host:9200 \
    [--source-version "ES 7.9"] \
    [--target-username USER --target-password PASS] \
    [--index-allowlist "index_a,index_b"] \
    [--max-shard-size-bytes 85899345920] \
    [--target-insecure] \
    [--documents-size-per-bulk-request 10485760] \
    [--max-connections 10]

Notes:
  - AWS credentials must be present in your environment (~/.aws or env vars).
  - This script runs the worker repeatedly until exit code 3 (no work left).
  - Local temp dirs are under $HOME to avoid macOS SIP restrictions.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage; exit 0
fi

IMAGE="public.ecr.aws/opensearchproject/opensearch-migrations-reindex-from-snapshot:latest"

# Required args
SNAPSHOT_NAME=""
S3_REPO_URI=""
S3_REGION=""
TARGET_HOST=""

# Optional args
SOURCE_VERSION="ES 7.9"
TARGET_USERNAME="${TARGET_USERNAME:-}"
TARGET_PASSWORD="${TARGET_PASSWORD:-}"
INDEX_ALLOWLIST=""
MAX_SHARD_SIZE_BYTES=""
TARGET_INSECURE=false
DOCS_SIZE_PER_BULK=""
MAX_CONNECTIONS=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot-name) SNAPSHOT_NAME="$2"; shift 2;;
    --s3-repo-uri) S3_REPO_URI="$2"; shift 2;;
    --s3-region) S3_REGION="$2"; shift 2;;
    --target-host) TARGET_HOST="$2"; shift 2;;
    --source-version) SOURCE_VERSION="$2"; shift 2;;
    --target-username) TARGET_USERNAME="$2"; shift 2;;
    --target-password) TARGET_PASSWORD="$2"; shift 2;;
    --index-allowlist) INDEX_ALLOWLIST="$2"; shift 2;;
    --max-shard-size-bytes) MAX_SHARD_SIZE_BYTES="$2"; shift 2;;
    --target-insecure) TARGET_INSECURE=true; shift 1;;
    --documents-size-per-bulk-request) DOCS_SIZE_PER_BULK="$2"; shift 2;;
    --max-connections) MAX_CONNECTIONS="$2"; shift 2;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$SNAPSHOT_NAME" || -z "$S3_REPO_URI" || -z "$S3_REGION" || -z "$TARGET_HOST" ]]; then
  echo "Missing required arguments" >&2
  usage
  exit 2
fi

# Create temp dirs under HOME to avoid macOS SIP (e.g., /var, /private/tmp nuances)
BASE_TMP="${HOME}/opensearch-rfs"
S3_DIR="${BASE_TMP}/s3_files"
LUCENE_DIR="${BASE_TMP}/lucene"
mkdir -p "$S3_DIR" "$LUCENE_DIR"

# Build ARG string
ARGS=(
  --snapshot-name "$SNAPSHOT_NAME"
  --s3-local-dir "$S3_DIR"
  --s3-repo-uri "$S3_REPO_URI"
  --s3-region "$S3_REGION"
  --lucene-dir "$LUCENE_DIR"
  --target-host "$TARGET_HOST"
  --source-version "$SOURCE_VERSION"
)

if [[ -n "$TARGET_USERNAME" ]]; then
  ARGS+=( --target-username "$TARGET_USERNAME" )
fi
if [[ -n "$TARGET_PASSWORD" ]]; then
  ARGS+=( --target-password "$TARGET_PASSWORD" )
fi
if [[ -n "$INDEX_ALLOWLIST" ]]; then
  ARGS+=( --index-allowlist "$INDEX_ALLOWLIST" )
fi
if [[ -n "$MAX_SHARD_SIZE_BYTES" ]]; then
  ARGS+=( --max-shard-size-bytes "$MAX_SHARD_SIZE_BYTES" )
fi
if [[ -n "$DOCS_SIZE_PER_BULK" ]]; then
  ARGS+=( --documents-size-per-bulk-request "$DOCS_SIZE_PER_BULK" )
fi
if [[ -n "$MAX_CONNECTIONS" ]]; then
  ARGS+=( --max-connections "$MAX_CONNECTIONS" )
fi
if [[ "$TARGET_INSECURE" == true ]]; then
  ARGS+=( --target-insecure )
fi

# Redacted echo
SAFE_ARGS=("${ARGS[@]}")
for i in "${!SAFE_ARGS[@]}"; do
  if [[ ${SAFE_ARGS[$i]} == "--target-password" ]]; then
    SAFE_ARGS[$((i+1))]="******"
  fi
done
echo "Running RFS with args: ${SAFE_ARGS[*]}"

# Docker env and volumes
DOCKER_ENV=(
  -e AWS_ACCESS_KEY_ID
  -e AWS_SECRET_ACCESS_KEY
  -e AWS_SESSION_TOKEN
  -e AWS_REGION="$S3_REGION"
)

DOCKER_MOUNTS=(
  -v "$S3_DIR":"$S3_DIR"
  -v "$LUCENE_DIR":"$LUCENE_DIR"
)

# Loop until exit code 3
EXIT=0
while true; do
  docker run --rm \
    "${DOCKER_ENV[@]}" \
    "${DOCKER_MOUNTS[@]}" \
    "$IMAGE" \
    /rfs-app/runJavaWithClasspath.sh org.opensearch.migrations.RfsMigrateDocuments "${ARGS[@]}"

  EXIT=$?
  if [[ $EXIT -eq 0 ]]; then
    echo "Shard migrated; continuing..."
  elif [[ $EXIT -eq 3 ]]; then
    echo "No work left (exit 3). Done."
    break
  else
    echo "RFS exited with code $EXIT. Stopping."
    exit "$EXIT"
  fi
  # Clean between runs similar to container entrypoint behavior
  rm -rf "$S3_DIR"/* || true
  rm -rf "$LUCENE_DIR"/* || true
done

