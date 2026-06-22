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
DRILL_DIR="/tmp/backup-drill-$(date +%Y%m%d-%H%M%S)"
FILTER="${1:-}"

passed=0
failed=0
skipped=0
results=()

# Each entry: service|bucket|repo_suffix|restic_pw_var|s3_key_var|s3_secret_var|type
# repo_suffix is appended to the bucket path (DB backups use /restic subdir).
BACKUPS=(
  "authentik|authentik-backup|/restic|vault_authentik_restic_password|vault_authentik_backup_s3_access_key|vault_authentik_backup_s3_secret_key|postgres"
  "authentik|authentik-volumes-backup||vault_authentik_restic_password|vault_authentik_volumes_backup_s3_access_key|vault_authentik_volumes_backup_s3_secret_key|restic"
  "nextcloud|nextcloud-backup|/restic|vault_nextcloud_restic_password|vault_nextcloud_backup_s3_access_key|vault_nextcloud_backup_s3_secret_key|postgres"
  "nextcloud|nextcloud-data-backup||vault_nextcloud_restic_password|vault_nextcloud_data_backup_s3_access_key|vault_nextcloud_data_backup_s3_secret_key|restic"
  "vaultwarden|vaultwarden-backup|/restic|vault_vaultwarden_restic_password|vault_vaultwarden_backup_s3_access_key|vault_vaultwarden_backup_s3_secret_key|postgres"
  "vaultwarden|vaultwarden-data-backup||vault_vaultwarden_restic_password|vault_vaultwarden_data_backup_s3_access_key|vault_vaultwarden_data_backup_s3_secret_key|restic"
  "prowlarr|prowlarr-backup||vault_prowlarr_restic_password|vault_prowlarr_backup_s3_access_key|vault_prowlarr_backup_s3_secret_key|restic"
  "radarr|radarr-backup||vault_radarr_restic_password|vault_radarr_backup_s3_access_key|vault_radarr_backup_s3_secret_key|restic"
  "sonarr|sonarr-backup||vault_sonarr_restic_password|vault_sonarr_backup_s3_access_key|vault_sonarr_backup_s3_secret_key|restic"
  "jellyfin|jellyfin-backup||vault_jellyfin_restic_password|vault_jellyfin_backup_s3_access_key|vault_jellyfin_backup_s3_secret_key|restic"
  "jellyseerr|jellyseerr-backup||vault_jellyseerr_restic_password|vault_jellyseerr_backup_s3_access_key|vault_jellyseerr_backup_s3_secret_key|restic"
  "qbittorrent|qbittorrent-backup||vault_qbittorrent_restic_password|vault_qbittorrent_backup_s3_access_key|vault_qbittorrent_backup_s3_secret_key|restic"
)

get_vault_var() {
  local group="$1" var="$2"
  cd "$REPO_ROOT"
  uv run ansible "$group" -m debug -a "msg={{ ${var} }}" 2>/dev/null \
    | grep -oP '"msg": "\K[^"]+' | head -1
}

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
  local target="${DRILL_DIR}/${service}/${bucket}"
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
  if [ "$type" = "postgres" ]; then
    local dump
    dump="$(find "$target" -name '*.dump' -o -name '*.sql' -o -name '*.pgdump' 2>/dev/null | head -1)"
    if [ -z "$dump" ]; then
      dump="$(find "$target" -type f -size +0c 2>/dev/null | head -1)"
    fi
    if [ -z "$dump" ]; then
      echo "  FAIL: no dump file found after restore"
      failed=$((failed + 1))
      results+=("FAIL  ${label} — no dump file in snapshot")
      return
    fi
    local size
    size="$(stat --format='%s' "$dump" 2>/dev/null || stat -f '%z' "$dump" 2>/dev/null)"
    echo "  Found dump: $(basename "$dump") (${size} bytes)"
    if [ "${size:-0}" -eq 0 ]; then
      echo "  FAIL: dump file is empty"
      failed=$((failed + 1))
      results+=("FAIL  ${label} — empty dump file")
      return
    fi
    if command -v pg_restore &>/dev/null; then
      if pg_restore --list "$dump" >/dev/null 2>&1; then
        echo "  pg_restore --list: valid archive"
      else
        echo "  (dump is not pg custom format — may be plain SQL, still valid)"
      fi
    fi
  else
    local count
    count="$(find "$target" -type f 2>/dev/null | wc -l)"
    echo "  Restored ${count} file(s)"
    if [ "$count" -eq 0 ]; then
      echo "  WARN: no files in snapshot (volume may be empty)"
      results+=("WARN  ${label} — 0 files (empty volume?)")
      passed=$((passed + 1))
      return
    fi
  fi

  echo "  OK"
  passed=$((passed + 1))
  results+=("OK    ${label}")
}

main() {
  check_prereqs
  echo "=== Local backup restore drill ==="
  echo "Drill directory: ${DRILL_DIR}"
  echo "S3 endpoint:     ${S3_ENDPOINT}"
  mkdir -p "$DRILL_DIR"

  for entry in "${BACKUPS[@]}"; do
    IFS='|' read -r service bucket suffix pw_var key_var secret_var type <<< "$entry"
    if [ -n "$FILTER" ] && [ "$service" != "$FILTER" ]; then
      continue
    fi
    drill_one "$service" "$bucket" "$suffix" "$pw_var" "$key_var" "$secret_var" "$type"
  done

  # Clean up secrets from env
  unset RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

  echo ""
  echo "=== Summary ==="
  for r in "${results[@]}"; do
    echo "  $r"
  done
  echo ""
  echo "Passed: ${passed}  Failed: ${failed}  Skipped: ${skipped}"
  echo ""
  echo "Drill data in: ${DRILL_DIR}"
  echo "Clean up with: rm -rf ${DRILL_DIR}"
}

main
