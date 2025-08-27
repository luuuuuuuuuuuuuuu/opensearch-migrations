#!/usr/bin/env bash

set -euo pipefail
set +H

# Native macOS runner for Reindex-from-Snapshot without Docker
# - Uses Gradle wrapper to run the CLI main class
# - Creates temp dirs under $HOME to avoid SIP-protected paths
# - Loops until exit code 3 (NoWorkLeft)

usage() {
  cat <<'USAGE'
Usage:
  ./reindex-from-snapshot-macos-native.sh \
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

Requirements:
  - Java 17 available (Gradle will compile and run the app). You can install via SDKMAN or Homebrew.
  - AWS credentials in your environment (~/.aws or env vars) for S3 access.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage; exit 0
fi

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
INITIAL_LEASE_DURATION="PT30M"

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
    --initial-lease-duration) INITIAL_LEASE_DURATION="$2"; shift 2;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$SNAPSHOT_NAME" || -z "$S3_REPO_URI" || -z "$S3_REGION" || -z "$TARGET_HOST" ]]; then
  echo "Missing required arguments" >&2
  usage
  exit 2
fi

# Create temp dirs under HOME
BASE_TMP="${HOME}/opensearch-rfs"
S3_DIR="${BASE_TMP}/s3_files"
LUCENE_DIR="${BASE_TMP}/lucene"
mkdir -p "$S3_DIR" "$LUCENE_DIR"

# Sanitize source version to avoid shell/gradle splitting issues on spaces
SOURCE_VERSION_SANITIZED="${SOURCE_VERSION// /_}"

ARGS=(
  --snapshot-name "$SNAPSHOT_NAME"
  --s3-local-dir "$S3_DIR"
  --s3-repo-uri "$S3_REPO_URI"
  --s3-region "$S3_REGION"
  --lucene-dir "$LUCENE_DIR"
  --target-host "$TARGET_HOST"
  --source-version "$SOURCE_VERSION_SANITIZED"
)

# Do NOT pass credentials via CLI to avoid escaping issues; use env vars instead
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
# Set a longer initial lease by default (30 minutes) unless overridden
ARGS+=( --initial-lease-duration "$INITIAL_LEASE_DURATION" )

# Redacted echo
SAFE_ARGS=("${ARGS[@]}")
for i in "${!SAFE_ARGS[@]}"; do
  if [[ ${SAFE_ARGS[$i]} == "--target-password" ]]; then
    SAFE_ARGS[$((i+1))]="******"
  fi
done

# Prepare Metadata Migration args (prepend the 'migrate' subcommand)
META_ARGS=(
  migrate
  --snapshot-name "$SNAPSHOT_NAME"
  --s3-local-dir "$S3_DIR"
  --s3-repo-uri "$S3_REPO_URI"
  --s3-region "$S3_REGION"
  --target-host "$TARGET_HOST"
  --source-version "$SOURCE_VERSION_SANITIZED"
)
if [[ "$TARGET_INSECURE" == true ]]; then
  META_ARGS+=( --target-insecure )
fi

META_SAFE_ARGS=("${META_ARGS[@]}")
for i in "${!META_SAFE_ARGS[@]}"; do
  if [[ ${META_SAFE_ARGS[$i]} == "--target-password" ]]; then
    META_SAFE_ARGS[$((i+1))]="******"
  fi
done
echo "Running Metadata Migration with args: ${META_SAFE_ARGS[*]}"

META_ARGS_ESCAPED=""
for a in "${META_ARGS[@]}"; do
  if [[ -z "$META_ARGS_ESCAPED" ]]; then
    META_ARGS_ESCAPED="$(shell_escape "$a")"
  else
    META_ARGS_ESCAPED+=" "
    META_ARGS_ESCAPED+="$(shell_escape "$a")"
  fi
done
echo "Running RFS (native) with args: ${SAFE_ARGS[*]}"

# Build escaped single-string for Gradle --args to preserve tokens
shell_escape() { printf '%q' "$1"; }
ARGS_ESCAPED=""
for a in "${ARGS[@]}"; do
  if [[ -z "$ARGS_ESCAPED" ]]; then
    ARGS_ESCAPED="$(shell_escape "$a")"
  else
    ARGS_ESCAPED+=" "
    ARGS_ESCAPED+="$(shell_escape "$a")"
  fi
done

# Build then run repeatedly (avoid daemon/config cache to reduce lock issues)
export GRADLE_USER_HOME="${HOME}/.gradle-opensearch-migrations"
GRADLE_FLAGS=(--no-daemon --no-configuration-cache)

# Export credentials for both tools if provided to this script
if [[ -n "${TARGET_USERNAME}" ]]; then export TARGET_USERNAME="${TARGET_USERNAME}"; fi
if [[ -n "${TARGET_PASSWORD}" ]]; then export TARGET_PASSWORD="${TARGET_PASSWORD}"; fi

./gradlew "${GRADLE_FLAGS[@]}" :DocumentsFromSnapshotMigration:build -x test

# 1) Run Metadata Migration first (idempotent)
./gradlew "${GRADLE_FLAGS[@]}" :MetadataMigration:run --args="$META_ARGS_ESCAPED"

while true; do
  ./gradlew "${GRADLE_FLAGS[@]}" :DocumentsFromSnapshotMigration:run --args="$ARGS_ESCAPED" || EXIT=$? || true
  EXIT=${EXIT:-0}
  if [[ $EXIT -eq 0 ]]; then
    echo "Shard migrated; continuing..."
  elif [[ $EXIT -eq 3 ]]; then
    echo "No work left (exit 3). Done."
    break
  else
    echo "RFS exited with code $EXIT. Stopping."
    exit "$EXIT"
  fi
  # Clean between runs
  rm -rf "$S3_DIR"/* || true
  rm -rf "$LUCENE_DIR"/* || true
  unset EXIT
done

