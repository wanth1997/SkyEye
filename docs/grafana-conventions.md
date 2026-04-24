# Grafana dashboard conventions

SkyEye hosts Grafana for all wanbrain products. This file is the source of truth for folder structure, naming, tagging, and provisioning rules — read before creating or editing any dashboard.

## Folder taxonomy

| Folder | What goes here | Examples |
|---|---|---|
| **Overview** | Cross-product / top-level summaries — first dashboards a stakeholder sees | `Overview — All products`, `Overview — Revenue today` |
| **Hosts** | Host-level metrics, reusable across products via `$product` variable | `Hosts — Node exporter`, `Hosts — Disk deep dive` |
| **{Product}** (one folder per product, e.g. `PPClub`, `enyoung`) | Everything specific to that product — backend, business metrics, customer flows | `PPClub — Backend overview`, `PPClub — Payment funnel` |
| **Edge** | Caddy / Cloudflare / DNS / external API probes | `Edge — Caddy`, `Edge — External API health` |
| **SkyEye** | Self-monitoring: Prometheus TSDB, Loki ingestion, Alertmanager pipeline, Grafana itself | `SkyEye — Stack health` |
| **Utilities** | Ad-hoc, experimental, or tooling dashboards | `Utilities — Blackbox probe explorer` |

Folders are **auto-created** from the filesystem layout under `grafana/dashboards/`. Creating a new folder = `mkdir grafana/dashboards/{Folder}/` and drop a JSON file inside.

## Naming

| Field | Format | Example |
|---|---|---|
| **Dashboard title** | `{Product or Scope} — {Description}` (em dash, not hyphen) | `PPClub — Backend overview` |
| **Dashboard UID** | `{product}-{scope}` all lowercase kebab-case, pinned, never changed | `ppclub-backend-overview` |
| **File path** | `grafana/dashboards/{Folder}/{uid}.json` | `grafana/dashboards/PPClub/ppclub-backend-overview.json` |
| **Tags** | `layer:{overview|host|app|edge|business|infra}`, `provisioned`, and optional `product:{name}` | `["layer:app", "product:ppclub", "provisioned"]` |

UIDs matter: URLs and bookmarks reference them. Changing a UID breaks bookmarks. Pick carefully up-front and treat as public API.

## Datasource references

Datasources have **pinned UIDs** (see `grafana/provisioning/datasources/default.yml`):

| Datasource | UID |
|---|---|
| Prometheus | `prometheus` |
| Loki | `loki` |
| Alertmanager | `alertmanager` |

Dashboard JSON MUST reference datasources by UID, not `"-- Default --"` or the display name. Example:

```json
"datasource": { "type": "prometheus", "uid": "prometheus" }
```

## Variables

Standard variables every multi-resource dashboard should expose, in order:

```
$product    — query: label_values(<any metric>, product)
$server_id  — query: label_values(<any metric>{product="$product"}, server_id)
$instance   — query: label_values(<any metric>{product="$product",server_id="$server_id"}, instance)
```

A dashboard hard-coded to a single product should omit `$product` and note the binding in the description.

## Required panels for overview dashboards

An "Overview" dashboard (anything in the `Overview/` folder) should have at minimum:

1. **Status row** — `up{}` count, active alerts count (from Alertmanager or `ALERTS{alertstate="firing"}`), log throughput
2. **Resource gauges** — CPU %, RAM %, disk %, scoped by `$product`
3. **Trends** — at least one time-series showing direction over last hour
4. **Alert list** — current firing / pending alerts (`alertlist` panel)

## Workflow — creating a new dashboard

1. **Build in the UI** — starting from a copy of an existing one or blank. Set: title, tags, UID (Settings → JSON Model → `uid`), datasources by UID.
2. **Sanity check against conventions** in this doc.
3. **Share → Export → Save to file** → commit JSON to `grafana/dashboards/{Folder}/{uid}.json`.
4. **`docker compose restart grafana`** (or wait up to 60 s — provider polls).
5. Confirm the provisioned copy loads correctly and that your UI edits are gone (UI edits are ephemeral once the file exists).

## Workflow — modifying a provisioned dashboard

- UI edits DO persist until the next provisioning poll (~60 s) — then they get reverted to the committed JSON.
- To persist: UI edit → Share → Export → Save to file → git commit.
- Never "Save as" inside the provisioned folder — creates a DB-only copy that conflicts with provisioning.

## CI / validation

TODO (low priority): add a pre-commit hook that runs `jq` against every dashboard JSON to verify:
- `uid` is kebab-case and non-empty
- `title` starts with one of the approved product / scope prefixes
- Every `datasource` reference uses a pinned UID
- File path matches UID (`grafana/dashboards/{Folder}/{uid}.json`)

## Dashboard inventory (as of commit date)

| Folder | Title | UID | Source |
|---|---|---|---|
| Overview | Overview — All products | `overview-all` | Built in-house |
| Hosts | Hosts — Node exporter | `hosts-node-exporter` | grafana.com ID 1860, rewritten for pinned UID + `$product` variable |
| PPClub | PPClub — Backend overview | `ppclub-backend-overview` | Built in-house (replaces grafana.com 18739; queries adapted to our `product` / `status` label shape) |
| PPClub | PPClub — Business | `ppclub-business` | Built in-house — payment / refund / external API / scheduler heartbeats |
| SkyEye | SkyEye — Stack health | `skyeye-stack-health` | Built in-house — meta-monitoring: Prom TSDB / Loki ingest / AM notifications / Grafana HTTP / blackbox |
| enyoung | enyoung — 日誌總覽 | `enyoung-logs-overview` | Log-derived observability: LogQL regexp parser extracts method/status/duration from Go chi access log. Stand-in until enyoung exposes `/metrics`. |
| ZenIncome | ZenIncome — 日誌總覽 | `zenincome-logs-overview` | Log-derived: log level / business event / symbol / source file breakdown. Go Bitfinex funding-rate bot, no /metrics yet. |

Add a row here each time a new dashboard is committed.
