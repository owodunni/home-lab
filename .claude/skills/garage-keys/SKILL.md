---
name: garage-keys
description: How this home lab provisions Garage S3 buckets and API keys. Use when a service needs S3 storage or a backup target on Garage — generating credentials, adding a bucket/key, or writing the provisioning play. Covers the pre-generate-and-import convention (we never use `garage key create`).
---

# Provisioning Garage S3 buckets and keys

## The convention: bring your own credentials

We **do not** let Garage mint credentials with `garage key create` (random
secret, shown once, must be copy-pasted back). Instead a **human** pre-generates
a key pair and vaults it; the **playbook** then `garage key import`s it. This way:

- credentials exist in vault *before* the first run — provisioning is unattended,
- the same key survives a Garage rebuild (re-imported, not regenerated),
- the consuming service and its bucket/key share one source of truth.

Steps 1–2 are a one-time **manual** action by the operator. Step 3 is the
**automated** part that the playbook performs on every run.

## Step 1 — Generate a key pair (human, manual)

```bash
scripts/garage-keygen.sh <vault-prefix>     # e.g. vault_authentik_backup_s3
```

It prints a Garage-format pair as ready-to-vault YAML. Garage validates the
format on import, so don't hand-roll it: access key is `GK` + 24 hex chars,
secret is 64 hex chars (the script handles this).

## Step 2 — Vault the credentials (human, manual)

The operator adds both halves to the **consuming service's**
`group_vars/<service>/vault.yml` (via `/vault`), named
`vault_<service>_<purpose>_s3_access_key` / `..._secret_key`. The non-secret
config (bucket name, endpoint, region) goes in `group_vars/<service>/main.yml`.
Config travels with the service, never with Garage. Nothing is committed
unencrypted; no secret is ever printed back by a play.

## Step 3 — Provision the bucket + key (playbook, automated)

Add a play **to the service's own playbook** that targets the Garage host (the
`garage` CLI lives only there) and runs *before* the service deploys. Keep this
in the service playbook — `playbooks/garage.yml` stays a pure infrastructure
playbook with no knowledge of its consumers. Pull the service's vars via the
service group so the play needs no edit when the service moves hosts:

```yaml
- name: Provision <service> buckets and keys on Garage
  hosts: garage
  become: true
  vars:
    _host: "{{ groups['<service>'][0] }}"
    # One list entry per bucket/key pair the service needs — loop the tasks
    # below over this so adding a 3rd backup target needs no new tasks.
    _garage_resources:
      - bucket: "{{ hostvars[_host]['<service>_..._s3_bucket'] }}"
        access_key: "{{ hostvars[_host]['vault_<service>_..._s3_access_key'] }}"
        secret_key: "{{ hostvars[_host]['vault_<service>_..._s3_secret_key'] }}"
  tasks:
    # garage bucket list / create, looping over _garage_resources
    #   (when item.bucket not in stdout)
    # garage key list, then loop over _garage_resources, when item.bucket not in stdout:
    #   garage key import --yes -n {{ item.bucket }} {{ item.access_key }} {{ item.secret_key }}
    #     -> no_log: true  (secret on the command line)
    #   garage bucket allow {{ item.bucket }} --read --write --key {{ item.access_key }}
    #     -> bucket is positional here, unlike `key import -n` (a flag)
```

All tasks are idempotent: the `list` checks short-circuit on re-runs. The play
only *imports* the vaulted key — it never mints one, so a missing vault var is an
operator error (do Steps 1–2 first), not something the play papers over.

## Layer ordering

Garage (the `services` layer) must run **before** any layer that consumes it, so
its buckets/keys exist first. See the ordering rationale in CLAUDE.md.

## Reference implementation

`playbooks/authentik.yml` (first play) — the Authentik backup buckets.
Verified against Garage v2.3.0:
- `garage key import` takes `-n` (not `--name`); `--yes` is required.
- `garage bucket allow` takes the bucket name as a **positional** argument,
  not `--bucket` — that flag doesn't exist and errors with "Found argument
  '--bucket' which wasn't expected".
