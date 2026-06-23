#!/usr/bin/env bash
# Local backup restore drill — verify every service backup is restorable from
# this workstation, without touching any server. Connects directly to Garage S3
# on valen and restores each repo's latest snapshot to a temp directory.
#
# Prerequisites:
#   - restic installed (apt install restic / brew install restic)
#   - This machine can reach s3.jardoole.xyz (home LAN or VPN)
#   - Ansible vault password available (vault_passwords/all.txt)
#
# Usage:
#   scripts/local-drill.sh              # drill all services
#   scripts/local-drill.sh authentik    # drill one service
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S3_ENDPOINT="https://s3.jardoole.xyz"
S3_REGION="garage"
# Restores land in ${DRILL_BASE}/<service>/${RUN_TS}/<bucket> — service first,
# then this run's timestamp.
DRILL_BASE="/tmp/backup-drill"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
FILTER="${1:-}"

passed=0
failed=0
skipped=0
results=()

# Shared helpers (get_vault_var, verify_restore, print_summary) and the drill
# manifest (BACKUPS) live here, so this drill and the offsite drill
# (scripts/offsite-drill.sh) exercise the exact same repo list.
source "${REPO_ROOT}/scripts/lib/drill-common.sh"

check_prereqs() {
  if ! command -v restic &>/dev/null; then
    echo "ERROR: restic is not installed. Install with: sudo apt install restic"
    exit 1
  fi
  if ! curl -sSk -o /dev/null -w '' "$S3_ENDPOINT" 2>/dev/null; then
    echo "ERROR: Cannot reach $S3_ENDPOINT — are you on the home LAN?"
    exit 1
  fi
}

drill_one() {
  local service="$1" bucket="$2" suffix="$3" pw_var="$4" key_var="$5" secret_var="$6" type="$7"
  local repo="s3:${S3_ENDPOINT}/${bucket}${suffix}"
  local target="${DRILL_BASE}/${service}/${RUN_TS}/${bucket}"
  local label="${service}/${bucket}"

  echo ""
  echo "--- ${label} (${type}) ---"

  echo "  Decrypting credentials..."
  local pw key secret
  pw="$(get_vault_var "$service" "$pw_var")"
  key="$(get_vault_var "$service" "$key_var")"
  secret="$(get_vault_var "$service" "$secret_var")"

  if [ -z "$pw" ] || [ -z "$key" ] || [ -z "$secret" ]; then
    echo "  SKIP: could not decrypt credentials for ${label}"
    skipped=$((skipped + 1))
    results+=("SKIP  ${label}")
    return
  fi

  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD="$pw"
  export AWS_ACCESS_KEY_ID="$key"
  export AWS_SECRET_ACCESS_KEY="$secret"

  echo "  Listing snapshots..."
  if ! restic snapshots --compact 2>&1; then
    echo "  FAIL: cannot list snapshots for ${label}"
    failed=$((failed + 1))
    results+=("FAIL  ${label} — cannot list snapshots")
    return
  fi

  echo "  Running restic check..."
  if ! restic check 2>&1; then
    echo "  FAIL: restic check failed for ${label}"
    failed=$((failed + 1))
    results+=("FAIL  ${label} — restic check failed")
    return
  fi

  echo "  Restoring latest snapshot to ${target}..."
  mkdir -p "$target"
  if ! restic restore latest --target "$target" 2>&1; then
    echo "  FAIL: restore failed for ${label}"
    failed=$((failed + 1))
    results+=("FAIL  ${label} — restore failed")
    return
  fi

  echo "  Verifying restore..."
  verify_restore "$type" "$target" "$label"
}

main() {
  check_prereqs
  echo "=== Local backup restore drill ==="
  echo "Drill data root: ${DRILL_BASE}/<service>/${RUN_TS}"
  echo "S3 endpoint:     ${S3_ENDPOINT}"
  mkdir -p "$DRILL_BASE"

  for entry in "${BACKUPS[@]}"; do
    IFS='|' read -r service bucket suffix pw_var key_var secret_var type <<< "$entry"
    if [ -n "$FILTER" ] && [ "$service" != "$FILTER" ]; then
      continue
    fi
    drill_one "$service" "$bucket" "$suffix" "$pw_var" "$key_var" "$secret_var" "$type"
  done

  # Clean up secrets from env
  unset RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

  print_summary
}

main
