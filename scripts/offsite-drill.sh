#!/usr/bin/env bash
# Offsite backup restore drill — verify every service backup is restorable from
# the OFFSITE copy (beelink), the offsite analogue of scripts/local-drill.sh
# (which drills the LOCAL copy in valen's Garage over S3).
#
# HOW IT KEEPS THE PASSWORD OFF BEELINK (the offsite security model — see
# docs/backups-offsite.md): restic runs HERE, on the workstation, and reaches
# beelink's mirrored repos over SFTP. beelink only ever returns opaque, already-
# encrypted restic objects; the repo is decrypted only on this machine, so the
# restic password never touches the offsite node. We also do NOT need restic
# installed on beelink (the mirror itself only uses rclone).
#
# The mirrored repos are root-owned but world-readable (they hold only encrypted
# packs), so the SSH login user can read them over SFTP — the backup_mirror role
# sets {{ backup_mirror_dest }} to mode 0755 for exactly this.
#
# Prerequisites:
#   - restic installed locally (apt install restic / brew install restic)
#   - SSH reachability to the [backup_mirror] host (beelink), the same path
#     Ansible uses (home LAN / WireGuard)
#   - Ansible vault password available (vault_passwords/all.txt) to decrypt each
#     service's restic password
#
# Usage:
#   scripts/offsite-drill.sh              # drill all services
#   scripts/offsite-drill.sh authentik    # drill one service
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Restores land in ${DRILL_BASE}/<service>/${RUN_TS}/<bucket> — service first,
# then this run's timestamp.
DRILL_BASE="/tmp/offsite-drill"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
FILTER="${1:-}"

passed=0
failed=0
skipped=0
results=()

# SFTP login (user@host) and the offsite repo root on beelink — both resolved
# from the inventory/group_vars in resolve_offsite() so this stays in sync when
# the host or path moves.
SFTP_TARGET=""
OFFSITE_DEST=""

# Shared helpers (get_vault_var, verify_restore, print_summary) and the drill
# manifest (BACKUPS) — the same repo list scripts/local-drill.sh uses.
source "${REPO_ROOT}/scripts/lib/drill-common.sh"

# Read one Ansible fact/var for the beelink host. Echoes the value or empty.
_ansible_value() {
  cd "$REPO_ROOT" || return 1
  uv run ansible backup_mirror -m debug -a "msg={{ $1 }}" 2>/dev/null \
    | grep -oP '"msg": "\K[^"]+' | head -1
}

resolve_offsite() {
  local host user
  host="$(_ansible_value 'ansible_host')"
  user="$(_ansible_value "ansible_user | default('')")"
  [ -z "$user" ] && user="$(whoami)"
  OFFSITE_DEST="$(_ansible_value 'backup_mirror_dest')"
  if [ -z "$host" ] || [ -z "$OFFSITE_DEST" ]; then
    echo "ERROR: could not resolve beelink host / offsite dest from the inventory."
    exit 1
  fi
  SFTP_TARGET="${user}@${host}"
}

check_prereqs() {
  if ! command -v restic &>/dev/null; then
    echo "ERROR: restic is not installed. Install with: sudo apt install restic"
    exit 1
  fi
  echo "Resolving offsite host from inventory..."
  resolve_offsite
  echo "Checking SSH to ${SFTP_TARGET}..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SFTP_TARGET" true 2>/dev/null; then
    echo "ERROR: cannot SSH to ${SFTP_TARGET} — is beelink reachable (home LAN / WireGuard)?"
    exit 1
  fi
}

drill_one() {
  # Same manifest fields as the local drill; the S3 key/secret (args 5,6) are
  # unused offsite — we reach the repo over SFTP, not S3.
  local service="$1" bucket="$2" suffix="$3" pw_var="$4" type="$7"
  local repo="sftp:${SFTP_TARGET}:${OFFSITE_DEST}/${bucket}${suffix}"
  local target="${DRILL_BASE}/${service}/${RUN_TS}/${bucket}"
  local label="${service}/${bucket}"

  echo ""
  echo "--- ${label} (${type}) ---"

  echo "  Decrypting restic password..."
  local pw
  pw="$(get_vault_var "$service" "$pw_var")"
  if [ -z "$pw" ]; then
    echo "  SKIP: could not decrypt restic password for ${label}"
    skipped=$((skipped + 1))
    results+=("SKIP  ${label}")
    return
  fi

  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD="$pw"

  echo "  Repo: ${repo}"
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
  echo "=== Offsite backup restore drill ==="
  echo "Drill data root: ${DRILL_BASE}/<service>/${RUN_TS}"
  echo "Offsite repos:   ${SFTP_TARGET}:${OFFSITE_DEST}"
  mkdir -p "$DRILL_BASE"

  for entry in "${BACKUPS[@]}"; do
    IFS='|' read -r service bucket suffix pw_var key_var secret_var type <<< "$entry"
    if [ -n "$FILTER" ] && [ "$service" != "$FILTER" ]; then
      continue
    fi
    drill_one "$service" "$bucket" "$suffix" "$pw_var" "$key_var" "$secret_var" "$type"
  done

  # Clean up the restic password from env.
  unset RESTIC_REPOSITORY RESTIC_PASSWORD

  print_summary
}

main
