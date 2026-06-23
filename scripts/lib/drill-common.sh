# shellcheck shell=bash
# Shared pieces for the restore drills — the single source of truth common to
# scripts/local-drill.sh (drills the LOCAL copy in valen's Garage over S3) and
# scripts/offsite-drill.sh (drills the OFFSITE copy on beelink over SFTP).
#
# Sourced, not executed. Callers must define: REPO_ROOT, the accumulator globals
# `passed` `failed` `skipped` `results`, and the scratch-path globals `DRILL_BASE`
# (e.g. /tmp/backup-drill) and `RUN_TS` (this run's timestamp) — print_summary
# reads them. Each restore lands in ${DRILL_BASE}/<service>/${RUN_TS}/<bucket>.

# Which restic repos the drills exercise. ONE list so adding a service updates
# both drills at once.
# KEEP IN SYNC with backup_mirror_buckets (group_vars/backup_mirror/main.yml):
# every bucket mirrored offsite should have a row here so both drills cover it.
#
# Each entry: service|bucket|repo_suffix|restic_pw_var|s3_key_var|s3_secret_var|type
#   repo_suffix   appended to the repo path — DB (postgres) repos live in a
#                 /restic subdir, volume/config repos sit at the repo root.
#   s3_key_var / s3_secret_var are used ONLY by the local (S3) drill; the offsite
#                 drill reaches the repo over SFTP and ignores them.
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

# Decrypt one vaulted variable from a service's group_vars via Ansible (the vault
# password file is configured in ansible.cfg). Echoes the value, or empty on miss.
get_vault_var() {
  local group="$1" var="$2"
  cd "$REPO_ROOT" || return 1
  uv run ansible "$group" -m debug -a "msg={{ ${var} }}" 2>/dev/null \
    | grep -oP '"msg": "\K[^"]+' | head -1
}

# Assert a restore landed something usable. For postgres: a non-empty dump file
# (validated with pg_restore --list when available). For restic volumes: at
# least one file (an empty volume is a WARN, not a failure). Updates the
# accumulators and `results`. Returns nothing; the caller's loop moves on.
verify_restore() {
  local type="$1" target="$2" label="$3"

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

# Print the run summary (shared output format for both drills).
print_summary() {
  echo ""
  echo "=== Summary ==="
  for r in "${results[@]}"; do
    echo "  $r"
  done
  echo ""
  echo "Passed: ${passed}  Failed: ${failed}  Skipped: ${skipped}"
  echo ""
  echo "Drill data under: ${DRILL_BASE}/<service>/${RUN_TS}/"
  echo "Clean up this run: rm -rf ${DRILL_BASE}/*/${RUN_TS}"
}
