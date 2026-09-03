# SkyEye

<!--
本檔案是這個專案 agent 指令的「單一來源」（Claude 透過 CLAUDE.md 的 @AGENTS.md import 讀取，
Codex 直接讀取本檔）。只放這個專案獨有的內容。

通用工作流規則（git worktree、work-log、project-brief、套件安全、驗證紀律）住在全域層：
- Claude: ~/.claude/CLAUDE.md
- Codex: ~/.codex/config.toml 的 developer_instructions
不要把全域規則複製進來，否則會產生多份副本各自漂移。
-->

## 專案是什麼

SkyEye 是 wanbrain 各產品共用的自架監控平台。它集中接收遠端主機的 metrics 與已去識別化 logs，透過 Grafana 顯示，並由 Alertmanager 將告警送往 Telegram 與 email。

## 架構速覽

- 中央端以 Docker Compose 執行 Prometheus、Loki、Grafana、Alertmanager、Blackbox Exporter 與 Cloudflare Tunnel。
- 被監控主機執行 Grafana Alloy，透過 Cloudflare Access Service Token 將 metrics remote-write 到 Prometheus、將 logs push 到 Loki。
- Prometheus rules 位於 `prometheus/rules/`；Loki ruler 目前使用單一 tenant directory `/loki/rules/fake/`。
- Grafana dashboard 由 `grafana/dashboards/` 的 JSON provisioning，datasource UID 固定為 `prometheus`、`loki`、`alertmanager`。
- High alerts 會送 Telegram 與 email；新告警必須先用 shadow routing 驗證，不能未經 canary 直接 paging。

## 驗證命令

```bash
docker compose config --quiet
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v2.54.1 \
  promtool check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" prom/alertmanager:v0.27.0 \
  amtool check-config /etc/alertmanager/alertmanager.yml
find grafana/dashboards -name '*.json' -exec jq empty {} +
```

涉及 Alloy、launchd 或 ruler 規則時，另執行文件指定的 `alloy validate`、`plutil -lint`、`promtool test rules` 與 `lokitool rules lint`。

## 專案特有規則與禁忌

- 不得更改既有 Grafana datasource UID；dashboard 與 bookmark 將其視為穩定介面。
- Dashboard 的持久來源是 Git 中的 JSON；Grafana UI 內未 export 的修改會被 provisioning 覆蓋。
- 不得將 Cloudflare、Telegram、SMTP 或 Grafana secret 寫入 Git；agent template 只能引用環境變數。
- Logs 必須在離開來源主機前完成敏感資訊 scrub；不得把本機絕對路徑、訂單 ID 或 client action ID 做成 Loki labels。
- 遠端 agent 必須主動 push；中央 Prometheus 不對產品主機開放 scrape port。
- Trading 類告警的 duplicate process、risk halt 與 telemetry missing 屬高風險狀態，規則必須先經 shadow 與 canary 驗證。
- Linux Trading monitoring 必須以 `skyeye-trading-probe@STRATEGY`、獨立 mode-0600 env、獨立 `tnauqquant-STRATEGY.prom` 與精確 log glob 隔離；共享 textfile collector 只能在所有 templated probe 停止且 timer disabled 時改寫。Mainnet strategy 未經 operator 指示不得由監控安裝器啟動。

## 相關文件

- `docs/project-brief.md` — 專案全貌與目前狀態
- `docs/work-log.md` — 工作記錄（最新在最上方）
- `monitoring-plan-v2.md` — 現有平台架構與歷史決策
- `docs/onboarding-new-product.md` — 一般產品 onboarding 流程
- `docs/grafana-conventions.md` — dashboard 命名與 provisioning 規則
- `docs/trading-monitoring-development-plan.md` — Trading monitoring 設計、跨 server contract 與開發計畫
- `docs/trading-runtime-contract-agent-spec.md` — 可直接交給 tnauqquant agent 的 runtime contract 規格
