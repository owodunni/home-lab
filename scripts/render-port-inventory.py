#!/usr/bin/env python3
"""Generate docs/port-inventory.md from hosts.ini + group_vars/host_vars.

Every host's firewall rules (`firewall_rules_*` list variables, see
docs/superpowers/specs/2026-07-19-host-firewalls-design.md) live scattered
across group_vars/host_vars, one variable per service/concern. This script
resolves inventory group membership, collects every `firewall_rules_*` list in
scope for each host, resolves the minimal `{{ var }}` templating used in the
rule data (ports, source-alias CIDRs), and renders one port table per host —
the single human-readable view of what a host's firewall will allow once
playbooks/firewall.yml is rolled out.

Run with no arguments to (re)write docs/port-inventory.md. Run with `--check`
(the pre-commit mode) to render in memory and fail if the committed file is
stale, mirroring scripts/check-blackbox-coverage.py's approach.

Vault files are never read: only `main.yml` / flat `<group>.yml` group_vars
and `main.yml` / flat `<host>.yml` host_vars files are parsed.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parent.parent
HOSTS_INI = REPO / "hosts.ini"
GROUP_VARS = REPO / "group_vars"
HOST_VARS = REPO / "host_vars"
OUTPUT_FILE = REPO / "docs" / "port-inventory.md"

GENERATE_CMD = "uv run scripts/render-port-inventory.py"

_TEMPLATE_RE = re.compile(r"^\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}$")
_FIREWALL_RULES_RE = re.compile(r"^firewall_rules_")


class InventoryError(Exception):
    """A fatal, loud failure resolving inventory or template data."""


# ============================================================================
# hosts.ini parsing
# ============================================================================


def parse_hosts_ini(path: Path) -> tuple[dict[str, list[str]], dict[str, list[str]], dict[str, str]]:
    """Return (group -> direct hosts, group -> child groups, host -> ansible_host)."""
    groups: dict[str, list[str]] = {}
    children: dict[str, list[str]] = {}
    host_ips: dict[str, str] = {}

    current: str | None = None
    current_is_children = False

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1]
            if name.endswith(":children"):
                current = name[: -len(":children")]
                current_is_children = True
                children.setdefault(current, [])
            else:
                current = name
                current_is_children = False
                groups.setdefault(current, [])
            continue
        if current is None:
            continue
        if current_is_children:
            children[current].append(line)
        else:
            parts = line.split()
            host = parts[0]
            groups[current].append(host)
            for part in parts[1:]:
                if part.startswith("ansible_host="):
                    host_ips[host] = part.split("=", 1)[1]

    return groups, children, host_ips


def host_group_closure(
    groups: dict[str, list[str]], children: dict[str, list[str]]
) -> dict[str, set[str]]:
    """Every host's full group membership, including transitive :children expansion.

    [parent:children] means members of each listed child group are also members
    of parent (e.g. [services:children] -> servers, desktop means every host in
    [servers] or [desktop] is also in [services]). Expanded to a fixed point so
    chains (servers -> services -> nfs_client) resolve fully. Every host is
    implicitly in "all".
    """
    direct: dict[str, set[str]] = {}
    for group, hosts in groups.items():
        for host in hosts:
            direct.setdefault(host, set()).add(group)

    # child_group -> set of parent groups it feeds into
    parent_of: dict[str, set[str]] = {}
    for parent, kids in children.items():
        for kid in kids:
            parent_of.setdefault(kid, set()).add(parent)

    result: dict[str, set[str]] = {}
    for host, own_groups in direct.items():
        closure = set(own_groups)
        changed = True
        while changed:
            changed = False
            for group in list(closure):
                for parent in parent_of.get(group, ()):
                    if parent not in closure:
                        closure.add(parent)
                        changed = True
        closure.add("all")
        result[host] = closure

    return result


# ============================================================================
# Variable loading
# ============================================================================


def _load_yaml(path: Path) -> dict[str, Any]:
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        raise InventoryError(f"{path} did not parse to a mapping")
    return data


def files_in_scope(host: str, host_groups: set[str]) -> list[Path]:
    """main.yml/flat-file group_vars for every group the host is in, plus its host_vars.

    Never includes vault.yml — only main.yml and flat <name>.yml variants.
    """
    files: list[Path] = []

    all_main = GROUP_VARS / "all" / "main.yml"
    if all_main.exists():
        files.append(all_main)

    for group in sorted(host_groups - {"all"}):
        group_main = GROUP_VARS / group / "main.yml"
        if group_main.exists():
            files.append(group_main)
        group_flat = GROUP_VARS / f"{group}.yml"
        if group_flat.exists():
            files.append(group_flat)

    host_main = HOST_VARS / host / "main.yml"
    if host_main.exists():
        files.append(host_main)
    host_flat = HOST_VARS / f"{host}.yml"
    if host_flat.exists():
        files.append(host_flat)

    return files


def collect_host_vars(files: list[Path]) -> dict[str, Any]:
    """Flatten every variable across the files in scope into one namespace.

    firewall_rules_* names are unique by convention (each concern owns one
    variable), so merge order does not matter for them. For everything else
    (ports, aliases, etc.) later files simply overwrite earlier ones, which
    matches every case actually present in this repo (each var is defined in
    exactly one file in scope for a given host).
    """
    namespace: dict[str, Any] = {}
    for path in files:
        namespace.update(_load_yaml(path))
    return namespace


def collect_firewall_rules(namespace: dict[str, Any]) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    for key, value in namespace.items():
        if _FIREWALL_RULES_RE.match(key):
            if not isinstance(value, list):
                raise InventoryError(f"{key} is not a list")
            rules.extend(value)
    return rules


# ============================================================================
# Minimal templating
# ============================================================================


def resolve(value: Any, namespace: dict[str, Any], path: tuple[str, ...] = ()) -> Any:
    """Resolve a whole-string "{{ var }}" value against namespace, recursively.

    Anything else (an int, a plain string, a non-matching template) passes
    through unchanged. Unresolvable or circular references fail loudly rather
    than emitting a placeholder.
    """
    if not isinstance(value, str):
        return value
    match = _TEMPLATE_RE.match(value.strip())
    if not match:
        return value
    var = match.group(1)
    if var in path:
        chain = " -> ".join(path + (var,))
        raise InventoryError(f"Circular template reference: {chain}")
    if var not in namespace:
        chain = " -> ".join(path + (var,)) if path else var
        raise InventoryError(f"Unresolvable template variable '{{{{ {var} }}}}' ({chain})")
    return resolve(namespace[var], namespace, path + (var,))


def resolve_aliases(namespace: dict[str, Any]) -> dict[str, str]:
    aliases = namespace.get("firewall_source_aliases") or {}
    return {name: resolve(value, namespace, (name,)) for name, value in aliases.items()}


def render_sources(sources: list[str], resolved_aliases: dict[str, str]) -> str:
    parts = []
    for source in sources:
        if source in resolved_aliases:
            parts.append(f"{source} ({resolved_aliases[source]})")
        else:
            # Not a known alias: the rule names a literal CIDR directly.
            parts.append(source)
    return ", ".join(parts)


def port_sort_key(port: Any) -> int:
    if isinstance(port, str) and ":" in port:
        return int(port.split(":", 1)[0])
    return int(port)


# ============================================================================
# Rendering
# ============================================================================

APPENDIX = f"""
## Notes

### Loopback convention

Services that publish only on `127.0.0.1` behind a co-located Traefik need no
firewall rule at all — nothing off-host can reach them regardless of the
firewall, so they are deliberately absent from every table above. This is the
default for most application containers in this lab (see CLAUDE.md's
"Application notes").

### Exposed today, deliberately blocked by the firewall (no allow rule)

These ports are bound to `0.0.0.0` (or otherwise reachable off-host) but have
**no** corresponding `firewall_rules_*` entry, so the default-deny baseline
blocks them outright:

- **Traefik's insecure dashboard, `:8080`**, on valen and beelink — operator
  confirmed unused; closed rather than relied upon to stay unenabled.
- **Garage RPC, `:3901`**, on valen — single-node deployment, no legitimate
  client ever needs the inter-node S3 protocol port.
- **Loki gRPC, `:9096`**, on pi-cm5-1 — Alloy pushes logs over the Traefik
  HTTPS route (`:443`), not this port.
- **Stale, never-uninstalled Garage on beelink, `:3900-3903`** — Garage moved
  to valen; removing the leftover install on beelink is a pending cleanup
  task, not yet done, so the ports still exist but stay firewalled off.

### NFSv3 helper ports

`rpc.mountd`, `rpc.statd`, and `lockd` normally bind an ephemeral port chosen
at boot, which cannot be named in a firewall rule. This lab pins them to fixed
ports via `/etc/nfs.conf.d` (see `playbooks/nfs.yml`), which is what makes the
`nfs-mountd-*` / `nfs-statd-*` / `nfs-lockd-*` rows above firewallable at all.

### beelink's barn LAN

beelink's local barn WiFi network shares the `192.168.1.0/24` CIDR with the
home LAN (see
`docs/superpowers/specs/2026-07-18-jellyfin-barn-relay-design.md`). Any rule
on beelink that allows `homelab_subnet` therefore also matches beelink's barn
neighbors numerically — there is no way to distinguish the two on this host.
This is an accepted risk, documented in
`docs/superpowers/specs/2026-07-19-host-firewalls-design.md` ("Risks &
accepted trade-offs").

### `docker*` scope

Rows flagged `docker*` in the Scope column are container ports Docker
publishes directly to `0.0.0.0`, bypassing ufw's INPUT chain entirely via
Docker's own FORWARD chains. The firewall role enforces these in the
`DOCKER-USER` iptables chain instead of a plain ufw rule — see the design
spec's "Docker-published ports" decision.
"""


def render_host_section(host: str, ip: str | None, rows: list[dict[str, Any]]) -> str:
    heading = f"## {host}" + (f" ({ip})" if ip else "")
    if not rows:
        return f"{heading}\n\nNo firewall rules declared for this host.\n"

    lines = [
        heading,
        "",
        "| Port | Proto | Scope | Allowed sources | Purpose |",
        "|---|---|---|---|---|",
    ]
    for row in rows:
        scope_display = "docker*" if row["scope"] == "docker" else row["scope"]
        lines.append(
            f"| {row['port']} | {row['proto']} | {scope_display} "
            f"| {row['sources']} | {row['comment']} |"
        )
    lines.append("")
    return "\n".join(lines)


def render_document(hosts: list[str], host_ips: dict[str, str], host_groups: dict[str, set[str]]) -> str:
    sections = []
    for host in sorted(hosts):
        files = files_in_scope(host, host_groups[host])
        namespace = collect_host_vars(files)
        resolved_aliases = resolve_aliases(namespace)
        raw_rules = collect_firewall_rules(namespace)

        rows = []
        for rule in raw_rules:
            try:
                port = resolve(rule["port"], namespace, (f"{rule['name']}.port",))
                sources = render_sources(
                    [resolve(s, namespace, (f"{rule['name']}.from",)) for s in rule["from"]],
                    resolved_aliases,
                )
            except InventoryError as exc:
                raise InventoryError(f"host {host}, rule '{rule.get('name', '?')}': {exc}") from exc
            rows.append(
                {
                    "port": port,
                    "proto": rule["proto"],
                    "scope": rule["scope"],
                    "sources": sources,
                    "comment": rule["comment"],
                }
            )
        rows.sort(key=lambda r: (port_sort_key(r["port"]), r["proto"]))

        sections.append(render_host_section(host, host_ips.get(host), rows))

    header = f"""<!--
GENERATED FILE — do not edit by hand.
Regenerate with `{GENERATE_CMD}` after changing any firewall_rules_* variable.
Source: hosts.ini + group_vars/*/main.yml + host_vars/*/main.yml
(see docs/superpowers/specs/2026-07-19-host-firewalls-design.md)
-->

# Port Inventory

Generated by `{GENERATE_CMD}`. **Do not edit this file directly** — it is
rendered from the `firewall_rules_*` variables in `group_vars`/`host_vars`.
Edit those and regenerate instead.

Each table lists, per host, every port the host firewall (`playbooks/firewall.yml`)
will allow inbound: the port/range, protocol, enforcement scope, the sources
allowed to reach it (`alias (CIDR)`, or a literal CIDR when a rule names one
directly), and the rule's purpose.

"""

    return header + "\n".join(sections) + APPENDIX


# ============================================================================
# main
# ============================================================================


def main() -> int:
    check_mode = "--check" in sys.argv[1:]

    groups, children, host_ips = parse_hosts_ini(HOSTS_INI)
    host_groups = host_group_closure(groups, children)
    all_hosts = sorted(host_groups.keys())

    try:
        rendered = render_document(all_hosts, host_ips, host_groups)
    except InventoryError as exc:
        print(f"port-inventory generation FAILED: {exc}", file=sys.stderr)
        return 1

    if check_mode:
        current = OUTPUT_FILE.read_text() if OUTPUT_FILE.exists() else None
        if current != rendered:
            print(
                f"port-inventory check FAILED: {OUTPUT_FILE} is stale.\n"
                f"Run `{GENERATE_CMD}` and commit the result.",
                file=sys.stderr,
            )
            if current is None:
                print(f"({OUTPUT_FILE} does not exist yet)", file=sys.stderr)
            else:
                # Cheap diff-ish hint without pulling in difflib output noise.
                old_lines = current.splitlines()
                new_lines = rendered.splitlines()
                for i, (a, b) in enumerate(zip(old_lines, new_lines)):
                    if a != b:
                        print(f"  first differing line {i + 1}:", file=sys.stderr)
                        print(f"    committed: {a}", file=sys.stderr)
                        print(f"    generated: {b}", file=sys.stderr)
                        break
                else:
                    if len(old_lines) != len(new_lines):
                        print(
                            f"  line count differs: committed {len(old_lines)}, "
                            f"generated {len(new_lines)}",
                            file=sys.stderr,
                        )
            return 1
        print(f"port-inventory check OK: {OUTPUT_FILE} is current.")
        return 0

    OUTPUT_FILE.write_text(rendered)
    print(f"Wrote {OUTPUT_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
