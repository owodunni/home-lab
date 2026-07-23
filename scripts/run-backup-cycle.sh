#!/usr/bin/env bash
# Retrigger the full nightly backup cycle on demand: run every service's
# backups (each sidecar's `backup` — the same code path its cron runs), then
# trigger beelink's offsite mirror pull. Use to validate a fix (e.g. after the
# firewall change that unblocked valen -> Garage S3) without waiting for the
# 02:00-09:00 service crons and the 06:00 mirror.
#
# Per service it invokes playbooks/run-backups.yml one group at a time — never a
# multi-group host pattern — because a host like valen belongs to many service
# groups and group_vars `backups:` manifests REPLACE (not merge), so only a
# single-group play has the right manifest in scope. This is the same reason
# verify-backups / restore-backups are service-scoped.
#
# Usage:
#   scripts/run-backup-cycle.sh            # all services, then the offsite mirror
#   scripts/run-backup-cycle.sh sonarr     # one service only (no mirror)
#
# Non-destructive: only writes new snapshots; never touches live service data.
# Confirm freshness afterwards with `make verify-backups SERVICE=<group>`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FILTER="${1:-}"

# Canonical list = every group_vars/<svc>/ that declares a `backups:` manifest,
# derived at runtime so a new backup service is picked up without editing this
# script (mirrors the manifest-driven playbooks — no second source of truth).
mapfile -t SERVICES < <(grep -rl '^backups:' group_vars/*/main.yml \
  | sed 's#group_vars/##; s#/main.yml##' | sort)

if [ "${#SERVICES[@]}" -eq 0 ]; then
  echo "ERROR: no services with a 'backups:' manifest found under group_vars/." >&2
  exit 1
fi

if [ -n "$FILTER" ] && ! printf '%s\n' "${SERVICES[@]}" | grep -qx "$FILTER"; then
  echo "ERROR: '$FILTER' has no 'backups:' manifest. Known: ${SERVICES[*]}" >&2
  exit 1
fi

failed=()

run_service() {
  local svc="$1"
  echo ""
  echo "=== Triggering backups: ${svc} ==="
  if ! uv run ansible-playbook playbooks/run-backups.yml -e "backup_service=${svc}"; then
    failed+=("$svc")
  fi
}

for svc in "${SERVICES[@]}"; do
  if [ -n "$FILTER" ] && [ "$svc" != "$FILTER" ]; then
    continue
  fi
  run_service "$svc"
done

# Offsite mirror pull — only in a full-cycle run (no single-service filter),
# after every service has written its fresh snapshots to Garage. Type=oneshot,
# so `systemctl start` blocks until the pull completes and its rc reflects it.
if [ -z "$FILTER" ]; then
  echo ""
  echo "=== Triggering offsite mirror pull (beelink) ==="
  if ! uv run ansible backup_mirror -b -a "systemctl start backup-mirror.service"; then
    failed+=("offsite-mirror")
  fi
fi

echo ""
echo "=== Backup cycle summary ==="
if [ "${#failed[@]}" -eq 0 ]; then
  echo "All triggered successfully."
  echo "Confirm freshness with: make verify-backups SERVICE=<group>"
else
  echo "FAILED: ${failed[*]}"
  exit 1
fi
