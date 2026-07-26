#!/usr/bin/env python3
"""Fail if a probed Traefik service is missing an AdGuard split-horizon rewrite.

`*.jardoole.xyz` names resolve on the LAN via AdGuard, whose service->host map
lives in `adguard_rewrites` (group_vars/adguard/main.yml). Unlike the router of
old, that list is hand-maintained, so a new service can be deployed and routed
while LAN/VPN clients silently resolve its PUBLIC Cloudflare record instead of the
LAN path (this is exactly how immich.jardoole.xyz slipped through). This guard
makes the omission a build failure.

Source of truth for "which services need a rewrite" is the SAME registry the
blackbox guard uses — `monitoring_blackbox_services` (group_vars/monitoring). Any
entry that is actually probed carries a `url`; its hostname must have a matching
`adguard_rewrites` entry. Entries that opt out with `probe: false` (e.g.
jellyfin-relay, barn-local on beelink and unreachable from the home LAN) carry no
`url` and are correctly skipped — they have no home-LAN name to rewrite.

The check is ONE-DIRECTIONAL: every probed service must have a rewrite, but a
rewrite may exist with no registry entry (host FQDNs, and non-probed routes that
still need LAN resolution such as mail's autoconfig/autodiscover endpoints), so
"extra" rewrites are not flagged. A typo'd rewrite domain still trips the check —
it shows up as the real name being missing.

Run as a pre-commit hook (and via `make precommit`); exits non-zero on a mismatch.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
REGISTRY_FILE = REPO / "group_vars" / "monitoring" / "main.yml"
ADGUARD_FILE = REPO / "group_vars" / "adguard" / "main.yml"


def _host_from_url(url: str) -> str:
    """`https://mail.{{ traefik_domain }}/x` -> `mail.{{ traefik_domain }}`.

    The `{{ traefik_domain }}` placeholder is left verbatim (both files carry it
    literally), so the derived host compares directly against a rewrite domain.
    """
    host = url.split("://", 1)[-1]
    return host.split("/", 1)[0].rstrip(".")


def probed_service_domains() -> set[str]:
    data = yaml.safe_load(REGISTRY_FILE.read_text()) or {}
    registry = data.get("monitoring_blackbox_services") or {}
    # Only entries with a `url` are probed / home-LAN routed; `probe: false`
    # opt-outs (jellyfin-relay) carry none and need no rewrite.
    return {_host_from_url(v["url"]) for v in registry.values() if isinstance(v, dict) and v.get("url")}


def rewrite_domains() -> set[str]:
    data = yaml.safe_load(ADGUARD_FILE.read_text()) or {}
    rewrites = data.get("adguard_rewrites") or []
    return {r["domain"] for r in rewrites if isinstance(r, dict) and r.get("domain")}


def main() -> int:
    missing = probed_service_domains() - rewrite_domains()

    if missing:
        print("AdGuard coverage check FAILED:\n")
        print(
            "Probed Traefik services with no adguard_rewrites entry in\n"
            "group_vars/adguard/main.yml (add `- domain: \"<name>.{{ traefik_domain }}\"`\n"
            "with the host FQDN as `answer:`, then redeploy `make app service=adguard`):\n"
            + "\n".join(f"  - {d}" for d in sorted(missing))
        )
        return 1

    print(f"AdGuard coverage OK: {len(probed_service_domains())} probed services all have a rewrite.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
