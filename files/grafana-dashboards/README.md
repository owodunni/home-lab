# Vendored Grafana dashboards

Dashboard JSON that has **no grafana.com dashboard ID**, so it cannot use the
`grafana_dashboards:` (download-by-id) mechanism in
`group_vars/monitoring/main.yml`. The grafana.grafana role provisions every
`*.json` here via `grafana_dashboards_dir`.

| File | Source | Notes |
|---|---|---|
| `intel-gpu.json` | [mike1808/igpu-exporter](https://github.com/mike1808/igpu-exporter) `example/dashboard.json` (commit `db2dace`) | Intel iGPU engine/power/per-process metrics for valen's QuickSync. The datasource template variable's `current` is cleared (`{}`) so Grafana binds it to the default Prometheus datasource on load — do NOT hardcode a datasource uid (pinning a uid on the datasource crashes Grafana's provisioner on uid change). |

To update: re-fetch upstream `example/dashboard.json`, clear the `datasource`
template variable's `current` to `{}`, and bump the pinned image commit in
`group_vars/media/main.yml` to match.
