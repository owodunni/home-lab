# roles/adguard

Deploys **AdGuard Home** on `pi-cm5-3` as the home network's filtering DNS
resolver — the single upstream the Ubiquiti router forwards to.

- **Filters:** ads/trackers (blocklists), adult content (Parental Control), and
  social media (Blocked Services).
- **Split-horizon in code:** service→host CNAMEs live here; the host A-records
  stay in Ubiquiti. A host-scoped upstream points those host names back at the
  router so the CNAMEs resolve to LAN IPs (and the LAN AAAA leak closes).
- **Config-as-code:** the templated `conf/AdGuardHome.yaml` is authoritative; the
  web UI is read-only. No backup job — the whole config is regenerable from git.
- **UI:** loopback-only. Reach it with `make adguard-ui` (SSH tunnel).

All configuration lives in `group_vars/adguard/`. Deploy with
`make app service=adguard`. See the design spec at
`docs/superpowers/specs/2026-07-24-adguard-dns-filter-design.md`, including the
two manual UniFi cutover steps.
