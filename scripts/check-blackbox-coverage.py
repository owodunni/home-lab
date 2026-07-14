#!/usr/bin/env python3
"""Fail if a routed Traefik service is missing from the blackbox monitoring registry.

Every service routed by Traefik has its own dynamic-config template
(playbooks/templates/traefik-<name>.yml.j2). For monitoring to be complete, each
such service must also appear in `monitoring_blackbox_services`
(group_vars/monitoring/main.yml) — either probed (kind: app/edge) or explicitly
exempt (probe: false with a reason). This guard makes forgetting a build failure,
so a new service cannot be added and silently left unmonitored.

Run as a pre-commit hook (and via `make precommit`); exits non-zero on a mismatch.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
TEMPLATE_DIR = REPO / "playbooks" / "templates"
REGISTRY_FILE = REPO / "group_vars" / "monitoring" / "main.yml"

# Traefik templates that are shared infrastructure, not routed services.
INFRA_TEMPLATES = {"wildcard-tls", "forward-auth", "static"}

_PREFIX = "traefik-"
_SUFFIX = ".yml.j2"


def routed_services() -> set[str]:
    names = set()
    for path in TEMPLATE_DIR.glob(f"{_PREFIX}*{_SUFFIX}"):
        name = path.name[len(_PREFIX):-len(_SUFFIX)]
        if name not in INFRA_TEMPLATES:
            names.add(name)
    return names


def registry_services() -> set[str]:
    data = yaml.safe_load(REGISTRY_FILE.read_text()) or {}
    registry = data.get("monitoring_blackbox_services") or {}
    return set(registry.keys())


def main() -> int:
    routed = routed_services()
    registered = registry_services()

    missing = routed - registered
    extra = registered - routed

    problems = []
    if missing:
        problems.append(
            "Routed Traefik services with no monitoring_blackbox_services entry\n"
            "(add `kind: app`, `kind: edge`, or `probe: false` with a reason):\n"
            + "\n".join(f"  - {n}" for n in sorted(missing))
        )
    if extra:
        problems.append(
            "monitoring_blackbox_services entries with no matching Traefik route\n"
            "(remove them or fix the name):\n"
            + "\n".join(f"  - {n}" for n in sorted(extra))
        )

    if problems:
        print("blackbox coverage check FAILED:\n")
        print("\n\n".join(problems))
        return 1

    print(f"blackbox coverage OK: {len(routed)} routed services all registered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
