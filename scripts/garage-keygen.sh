#!/usr/bin/env bash
#
# garage-keygen.sh — generate a Garage-format S3 API key pair locally.
#
# Garage validates imported keys against the format it would have generated:
#   Access Key ID : "GK" + 24 lowercase hex chars  (26 chars total)
#   Secret Key    : 64 lowercase hex chars
# Generating them ourselves (instead of `garage key create`) lets us vault the
# credentials up front and have Ansible `garage key import` them unattended, so
# the same key survives a Garage rebuild with no copy-paste.
#
# Usage:
#   scripts/garage-keygen.sh                 # print a pair
#   scripts/garage-keygen.sh <var-prefix>    # also print ready-to-vault YAML
#
# Example:
#   scripts/garage-keygen.sh vault_authentik_backup_s3
#   → emits vault_authentik_backup_s3_access_key / _secret_key lines to paste
#     into the relevant group_vars/<service>/vault.yml (then `ansible-vault
#     encrypt` it, or add via `/vault`).
#
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl is required but not found in PATH" >&2
  exit 1
fi

# 12 random bytes -> 24 hex chars, prefixed with Garage's "GK" marker.
access_key="GK$(openssl rand -hex 12)"
# 32 random bytes -> 64 hex chars.
secret_key="$(openssl rand -hex 32)"

prefix="${1:-}"

if [[ -n "$prefix" ]]; then
  cat <<EOF
# Paste into the service's group_vars/<service>/vault.yml, then encrypt it.
${prefix}_access_key: "${access_key}"
${prefix}_secret_key: "${secret_key}"
EOF
else
  cat <<EOF
Access Key ID : ${access_key}
Secret Key    : ${secret_key}
EOF
fi
