#!/usr/bin/env python3
"""Fail if anything that feeds ufw's rules files carries a non-ASCII character.

ufw stores rule comments in user.rules and re-serializes both user.rules and
after.rules with an ascii-only encoder on every `ufw default ...` call
(backend_iptables.set_default_policy -> util.write_to_file, `bytes(line,
'ascii')`). A single non-ASCII byte — an em dash (U+2014), en dash, or curly
quote — does NOT fail the first apply but crashes every SUBSEQUENT one with
UnicodeEncodeError, stranding the host mid-play.

The firewall role already asserts on this at run time, but that is too late: the
bad character is committed and only surfaces on the second deploy. This guard
catches it at commit time, from the two sources that reach those files:

  1. `firewall_rules_*` entries in group_vars/host_vars — their `name`/`comment`
     become ufw rule comments.
  2. the DOCKER-USER templates (roles/firewall/templates/docker-user-block-v*.j2)
     — rendered verbatim into after.rules/after6.rules.

Vault files are never read (they hold no firewall rules and the repo forbids it).

Run as a pre-commit hook (and via `make precommit`); exits non-zero on a hit.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
VAR_DIRS = [REPO / "group_vars", REPO / "host_vars"]
DOCKER_USER_TEMPLATES = [
    REPO / "roles" / "firewall" / "templates" / "docker-user-block-v4.j2",
    REPO / "roles" / "firewall" / "templates" / "docker-user-block-v6.j2",
]

# Fields of a firewall rule that end up inside a ufw rule comment.
CHECKED_FIELDS = ("name", "comment")


def _non_ascii_chars(text: str) -> list[str]:
    """Return the distinct non-ASCII characters in `text`, in order of first use."""
    seen: dict[str, None] = {}
    for char in text:
        if ord(char) > 0x7F:
            seen.setdefault(char, None)
    return list(seen)


def _is_vault(path: Path) -> bool:
    if path.name == "vault.yml":
        return True
    try:
        return path.read_text(errors="ignore").startswith("$ANSIBLE_VAULT")
    except OSError:
        return False


def check_rule_vars() -> list[str]:
    problems: list[str] = []
    for var_dir in VAR_DIRS:
        if not var_dir.is_dir():
            continue
        for path in sorted(var_dir.rglob("*.yml")):
            if _is_vault(path):
                continue
            try:
                data = yaml.safe_load(path.read_text()) or {}
            except yaml.YAMLError:
                # Not a plain vars file we can parse (e.g. inline vault tags);
                # firewall rules never live in such a file.
                continue
            if not isinstance(data, dict):
                continue
            rel = path.relative_to(REPO)
            for var_name, value in data.items():
                if not var_name.startswith("firewall_rules_"):
                    continue
                if not isinstance(value, list):
                    continue
                for rule in value:
                    if not isinstance(rule, dict):
                        continue
                    for field in CHECKED_FIELDS:
                        field_value = rule.get(field)
                        if not isinstance(field_value, str):
                            continue
                        bad = _non_ascii_chars(field_value)
                        if bad:
                            problems.append(
                                f"  {rel}: {var_name} -> {field}: "
                                f"{bad!r} in {field_value!r}"
                            )
    return problems


def check_templates() -> list[str]:
    problems: list[str] = []
    for path in DOCKER_USER_TEMPLATES:
        if not path.exists():
            continue
        rel = path.relative_to(REPO)
        for lineno, line in enumerate(path.read_text().splitlines(), start=1):
            bad = _non_ascii_chars(line)
            if bad:
                problems.append(f"  {rel}:{lineno}: {bad!r} in {line.strip()!r}")
    return problems


def main() -> int:
    problems = check_rule_vars() + check_templates()
    if problems:
        print("firewall ASCII check FAILED — non-ASCII would crash ufw on re-apply:\n")
        print("\n".join(problems))
        print(
            "\nReplace each with a plain ASCII equivalent "
            '(em/en dash -> "-", curly quotes -> straight).'
        )
        return 1
    print("firewall ASCII check OK: rule comments and DOCKER-USER templates are ASCII.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
