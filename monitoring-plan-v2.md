# 監控系統建置計畫 v2

> 2026-04-22 修訂。承接 [monitoring-plan.md](./monitoring-plan.md) 的方向，依據當前實機現況、舊 Guardian 架構、PPClub code 盤點重寫。
> Repo 名稱：**`SkyEye`**（即本 repo；實作時把監控相關檔案直接加到本 repo 根目錄）。

---

## 0. 從 v1 的差異摘要

| 議題 | v1 | v2（修正理由） |
|------|-----|---------------|
| Agent 模型 | node_exporter + promtail，中央 scrape | **Grafana Alloy，agent 主動 push 到中央** |
| 跨機傳輸 | VPC scrape（pull） | **Cloudflare Tunnel + Access Service Token（push）** |
| 通知通道 | LINE Notify | **Telegram Bot**（LINE Notify 已於 2025-03-31 停服） |
| Log 儲存 | 本機 EBS | **Loki chunks 放 S3**，冷熱分離、災難容錯自動 |
| Reverse proxy | 誤寫為 nginx | **Caddy**（實機為 Caddy，加 Caddy exporter） |
| 第二產品 | 假設未來 | **現在就有**：`enyoung-server`（port 8080）已併行 |
| 共機 or 獨立 | 先共機再搬 | **直接開獨立機**（遷移工程沒比較大，但換來運維乾淨） |
| PII 處理 | 泛談 | **具體 scrub regex**，姓名 / 手機 / email / 金額 |
| 告警分級 | 單一層 | **三層 High/Medium/Low**，不同通道 + 時段路由 |

---

## 1. 現況清查（實機觀察結果）

### 1.1 Guardian 舊棧（當前執行中）
- 位置：`/home/ubuntu/go/src/Guardian/`（是 git repo）
- 元件：Prometheus + Grafana + Loki + Promtail + node_exporter，全部 bind `127.0.0.1`
- **問題盤點**：
  - Grafana admin password = `admin`（明碼弱密碼）
  - 無 Alertmanager、無 rules 目錄 → 沒有告警能力
  - Promtail 只讀 `/tmp`，**沒在收 ppclub-backend 的 log**
  - Prom retention 寫死 `15d / 500MB`，不符合你要 60 天的需求
  - Scrape target 只有 `polymonitor`（交易策略、與 PPClub 無關）+ `node-exporter`
- **處置**：新建獨立環境完成 cutover 後，Guardian 停用；舊目錄保留讀檔，不再動。

### 1.2 PPClub Backend 現況
- 執行：`ppclub-backend.service`（systemd 管理）→ uvicorn 於 `127.0.0.1:8090`
- 反向代理：**Caddy**（非 nginx）—`ppclub.tw` 走 Caddy auto TLS + HTTP/3
- `/metrics` endpoint：**不存在**（curl 回 404） → Phase 2 要加
- Log 路徑：`journalctl -u ppclub-backend.service`
- **PII 洩漏實證**（從 log sample 擷取）：
  ```
  [create_payment] ... fields={'MerchantOrderNo': 'OP000006', 'Amt': '750',
    'ItemDesc': 'Open Play 2026-04-17', 'Email': 'wanth1997@gmail.com', ...}
  ```
  Email、訂單號、金額、品項都在 log 明文。
- Global exception handler 已存在於 `main.py:94`，可以掛 counter。

### 1.3 同機其他工作負載
- `enyoung-server`（port 8080）：內部工具，監控優先級較低，但同機共用資源
- `polymonitor` / `run_monitor`（port 8081）：交易策略，與 PPClub 無關，不動它
- PPClub EC2 規格：2 vCPU / 8 GB RAM / 62 GB EBS（用 36%）
- OS：Ubuntu 20.04（**2025-04 已 EOL**，列入風險清單）

### 1.4 舊 Guardian `remote-agent` 設計（保留借鑑）
- 用 **Grafana Alloy**（不是 node_exporter + promtail 組合）
- Push 走 Cloudflare Tunnel：`prom-push.wanbrain.com` / `loki-push.wanbrain.com`
- 認證：Cloudflare Access Service Token（`CF-Access-Client-Id` / `Secret` header）
- Prometheus `--web.enable-remote-write-receiver` 啟用
- **此架構保留**，v2 只是把 setup.sh 重構成更乾淨的版本

---

## 2. 終態架構

```
                      ┌───────────────────────────────────┐
                      │  monitoring-prod EC2              │
                      │  t4g.medium (ARM, 2vCPU / 4GB)    │
                      │  Ubuntu 24.04 / EBS 40GB gp3      │
                      │  無公開 port（走 Cloudflare tunnel）│
                      │                                   │
                      │  ┌──────────┐  ┌──────────┐      │
                      │  │Prometheus│  │Alertmgr  │      │
                      │  │(EBS TSDB)│  └────┬─────┘      │
                      │  └─────┬────┘       │            │
                      │        │            ▼            │
                      │  ┌─────▼────┐  ┌────────────┐    │
                      │  │  Loki    │  │  Telegram  │    │
                      │  │(idx+chunk│  │    Bot     │    │
                      │  │ → S3)    │  └────────────┘    │
                      │  └──────────┘                    │
                      │  ┌──────────┐  ┌──────────────┐  │
                      │  │ Grafana  │  │ cloudflared  │  │
                      │  │(SQLite EBS)│ │   tunnel    │  │
                      │  └──────────┘  └──────┬───────┘  │
                      └─────────────────────┬─┴──────────┘
                                            │
                         ┌──────────────────┴─────────────────┐
                         │         Cloudflare Zero Trust      │
                         │   prom-push.wanbrain.com (write)   │
                         │   loki-push.wanbrain.com (write)   │
                         │   grafana.wanbrain.com   (UI)      │
                         │   Access: Service Token / Google   │
                         └──────────────────┬─────────────────┘
                                            │
          ┌────────────────────┬────────────┼────────────┬─────────────────┐
          ▼                    ▼            ▼            ▼                 ▼
    [PPClub EC2]      [enyoung 同機]   [strategy-1]   [future-prod]   [future-any]
    Alloy              Alloy          Alloy          Alloy            Alloy
    ├ node metrics     ├ node metrics ├ node         ├ node           ├ node
    ├ /metrics(8090)   ├ /metrics?    ├ /metrics     ├ ...            └ ...
    └ journalctl       └ journalctl   └ log file
```

### 元件職責

| 元件 | 存什麼 | 回答什麼 |
|------|-------|---------|
| Prometheus | Metrics TSDB（local EBS） | 「過去 1 小時 5xx 比率？」 |
| Loki | Log index + chunks（S3） | 「那個 500 是誰觸發？」 |
| Grafana | UI + datasource（SQLite on EBS） | 「統一 dashboard」 |
| Alertmanager | 告警路由狀態 | 「誰要被通知、什麼時候」 |
| cloudflared | Tunnel client | 「把 9090/3100/3000 包成 HTTPS 公開端點」 |
| Grafana Alloy | Agent（每台被監控機一份） | 「Scrape 本機 + push 中央」 |

---

## 3. 告警分級設計

### 三層制（依用戶偏好）

| 層級 | 語意 | 觸發範例 | 通道 | 時段 |
|------|-----|---------|------|------|
| **High** | 服務無法提供 | backend down、5xx > 10%、磁碟 < 5%、連續 1hr 零付款 | **Telegram 立即推 + Email 備份** | 24/7 |
| **Medium** | 功能降級 / 可預測劣化 | 5xx > 5%、磁碟 < 20%、latency p99 > 3s | **Telegram** | **工作時間 09:00–21:00** |
| **Low** | 趨勢異常 / 資訊性 | 前日退款率上升 2x、新用戶註冊數偏低 | **Email digest** | 每日 09:00 匯總 |

### Alertmanager 路由（摘要）
```yaml
route:
  group_by: ['alertname', 'service']
  group_wait: 10s        # 同組告警等 10s 聚合
  group_interval: 5m
  repeat_interval: 4h    # 同告警 4 小時後才重發
  receiver: p2-telegram  # 預設
  routes:
    - match: { severity: High }
      receiver: p1-telegram-email
      group_wait: 0s
      repeat_interval: 30m
    - match: { severity: Medium }
      receiver: p2-telegram
      active_time_intervals: [work-hours]
    - match: { severity: Low }
      receiver: low-digest
      group_interval: 24h
      repeat_interval: 24h

time_intervals:
  - name: work-hours
    time_intervals:
      - times: [{ start_time: '09:00', end_time: '21:00' }]
        location: 'Asia/Taipei'
```

---

## 4. 技術決策

| 選擇 | 理由 |
|------|-----|
| **EC2 t4g.medium** | ARM Graviton 比同規格 t3 便宜 ~20%，Prom/Loki/Grafana 都有 arm64 image |
| **Ubuntu 24.04 LTS** | 20.04 已 EOL；22.04 也可，但 24.04 LTS 到 2029 |
| **EBS gp3 40GB** | Prom/Grafana/Alertmgr 存 local；S3 負責 log |
| **S3 for Loki** | 月費 ~$0.25，災難容錯免做；Loki 原生支援 |
| **EC2 Instance Profile** | IAM role attach 給 EC2，不用 access key |
| **S3 VPC Gateway Endpoint** | 免費；避免 S3 流量走 NAT gateway 計費 |
| **Cloudflare Tunnel** | 免費；不用開 public port；已有 infra |
| **Alloy (非 node_exporter + promtail)** | 單一 agent、單一 config、單一 systemd unit，運維更簡單 |
| **docker-compose** | k8s overkill；單機架構 |
| **Telegram Bot** | 免費、webhook 最簡、Markdown 支援 |

---

## 5. Phase 0 — Quick Wins（1 天，與 Phase 1 並行）

目的：零成本緩衝網，立即改善可觀測性。

- [ ] **UptimeRobot** — 對 `https://ppclub.tw/api/health` 做 1 分鐘 HTTPS probe，通知到 email
- [ ] **Sentry** — 建 2 個 project（FastAPI + React），DSN 存入 env
  - FastAPI：`pip install sentry-sdk[fastapi]`，`main.py` 加 `sentry_sdk.init(dsn=...)`
  - React：安裝 `@sentry/react` 並加 `Sentry.init`
  - 免費 tier 5k events/月，足夠
- [ ] **Guardian Grafana 密碼立刻改**（不等新機建好）
  ```bash
  cd /home/ubuntu/go/src/Guardian
  sed -i 's/GF_SECURITY_ADMIN_PASSWORD=admin/GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PW}/' docker-compose.yml
  export GF_ADMIN_PW='<32-char random>'
  docker compose up -d grafana
  ```
- [ ] **Telegram Bot 開好**
  - 跟 `@BotFather` 對話：`/newbot` → 拿到 `BOT_TOKEN`
  - 開一個 alert group，把 bot 加進去
  - 拿 `chat_id`：`curl https://api.telegram.org/bot<TOKEN>/getUpdates`
  - 兩個值先存 1Password / AWS Secrets Manager
- [ ] **CloudWatch CPU alarm 保留**（純 EC2 層 belt-and-suspenders）
  - 不要設 disk alarm（EC2 預設不 push 磁碟 metric，要裝 CW agent，直接放棄用 Phase 1 的 node metric 取代）

**驗收**：凌晨 server 掛了 UptimeRobot + CloudWatch 會叫醒你；Sentry 會自動收 React + FastAPI exception。

---

## 6. Phase 1 — 中央監控棧建置（3 天）

### 6.1 AWS 基礎設施

**EC2**
```
Name:         monitoring-prod
Instance:     t4g.medium (2 vCPU / 4 GB RAM)
AMI:          Ubuntu 24.04 LTS (arm64)
Storage:      40 GB gp3 (3000 IOPS / 125 MB/s baseline)
VPC:          同 PPClub（方便之後 SG 管理）
Subnet:       Public subnet（Cloudflare tunnel 需要 egress 443）
SG ingress:   22/tcp 從你家 IP / VPN only
SG egress:    443/tcp to 0.0.0.0/0（tunnel + S3 + apt + docker）
              53/udp  DNS
Elastic IP:   不需要
IAM Role:     monitoring-prod-role
  └─ Policy: S3 read/write 限定 loki + prometheus-snapshot bucket
Tags:         {env: prod, role: monitoring, owner: <your>}
```

**S3 Buckets**
```
skyeye-loki-chunks
├─ Region: ap-northeast-1
├─ Versioning: disabled
├─ Default encryption: SSE-S3
└─ Lifecycle:
   ├─ expire objects after 30 days
   └─ transition to Standard-IA after 7 days（可選，省 40%）

skyeye-prometheus-snapshots（決策已定：要做）
├─ Region: ap-northeast-1
├─ Lifecycle: expire after 30 days
└─ 用途：每日 snapshot TSDB，災難回復
```

**S3 Gateway Endpoint**（VPC 內）
- 在 monitoring-prod 所在 VPC 建 `com.amazonaws.ap-northeast-1.s3` gateway endpoint（免費）
- Attach 到 monitoring-prod 所在 subnet 的 route table
- S3 流量走 VPC 內網，不吃 NAT 費用

### 6.2 Repo 結構（新 repo）

本 repo（SkyEye）實作時在根目錄加入以下檔案：

```
SkyEye/
├── README.md
├── monitoring-plan.md            # v1（保留當 changelog）
├── monitoring-plan-v2.md         # 本文件
├── .gitignore                    # 排除 .env, secrets/
├── .env.example                  # 範本：GF_ADMIN_PW, TG_BOT_TOKEN, TG_CHAT_P1, ...
├── docker-compose.yml
├── prometheus/
│   ├── prometheus.yml
│   └── rules/
│       ├── system.yml            # CPU / RAM / disk
│       ├── app.yml               # 5xx / latency / up
│       ├── business.yml          # 付款 / 退款 / 報名 / credit
│       └── deadman.yml           # scheduler heartbeat
├── loki/
│   └── loki-config.yml           # S3 backend
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── default.yml
│   │   └── dashboards/
│   │       └── default.yml       # auto-load /var/lib/grafana/dashboards
│   └── dashboards/
│       ├── node.json             # import ID 1860 修改
│       ├── fastapi.json          # import ID 18739 修改
│       ├── caddy.json
│       ├── ppclub-business.json  # 自建
│       └── overview.json         # 多產品總覽
├── alertmanager/
│   └── alertmanager.yml
├── cloudflared/
│   └── config.yml
├── agents/
│   └── alloy/
│       ├── README.md
│       ├── setup.sh              # 一鍵安裝
│       ├── uninstall.sh
│       └── config.alloy.tmpl     # envsubst 產生
├── scripts/
│   ├── bootstrap-monitoring-ec2.sh   # 新機初始化
│   ├── backup-prometheus.sh          # cron 每日 snapshot → S3
│   ├── amtool-check.sh               # alert rule syntax 驗證
│   └── grafana-export-dashboards.sh  # UI → JSON → git
├── runbooks/
│   ├── README.md                 # runbook 寫作指引
│   ├── backend-down.md
│   ├── payment-zero.md
│   ├── disk-full.md
│   └── _template.md
└── docs/
    ├── architecture.md
    ├── phase-0-quickwins.md
    ├── phase-1-build.md
    ├── phase-2-instrument.md
    ├── phase-3-multiproduct.md
    ├── cutover-from-guardian.md
    └── ec2-sizing.md
```

### 6.3 關鍵檔案範本

**`docker-compose.yml`**
```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=30d
      - --storage.tsdb.retention.size=4GB
      - --web.enable-remote-write-receiver
      - --web.enable-lifecycle
    ports:
      - "127.0.0.1:9090:9090"

  loki:
    image: grafana/loki:3.0.0
    restart: unless-stopped
    volumes:
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml:ro
    command: -config.file=/etc/loki/local-config.yaml
    ports:
      - "127.0.0.1:3100:3100"
    # Loki reads AWS creds from EC2 instance profile — no env var needed

  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PW}
      - GF_SERVER_ROOT_URL=https://grafana.wanbrain.com
      # Auth via Cloudflare Access + auth.proxy — see §13.1
      - GF_AUTH_DISABLE_LOGIN_FORM=true
      - GF_AUTH_BASIC_ENABLED=false
      - GF_AUTH_PROXY_ENABLED=true
      - GF_AUTH_PROXY_HEADER_NAME=Cf-Access-Authenticated-User-Email
      - GF_AUTH_PROXY_HEADER_PROPERTY=email
      - GF_AUTH_PROXY_AUTO_SIGN_UP=true
      - GF_AUTH_PROXY_WHITELIST=127.0.0.1,172.16.0.0/12
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "127.0.0.1:3000:3000"

  alertmanager:
    image: prom/alertmanager:latest
    restart: unless-stopped
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    environment:
      - TG_BOT_TOKEN=${TG_BOT_TOKEN}
      - TG_CHAT_P1=${TG_CHAT_P1}
      - TG_CHAT_P2=${TG_CHAT_P2}
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_USER=${SMTP_USER}
      - SMTP_PASS=${SMTP_PASS}
    ports:
      - "127.0.0.1:9093:9093"

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARED_TUNNEL_TOKEN}

volumes:
  prometheus_data:
  loki_data: {}
  grafana_data:
  alertmanager_data:
```

**`prometheus/prometheus.yml`**
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: monitoring-prod

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

scrape_configs:
  # Monitoring machine self
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: alertmanager
    static_configs:
      - targets: ['alertmanager:9093']

  # All agent-pushed metrics come via remote-write — no scrape needed here.
  # Agents set external_labels {product, server_id}, so no per-target config.
```

**`loki/loki-config.yml`**（S3 backend 重點片段）
```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    s3:
      bucketnames: skyeye-loki-chunks
      region: ap-northeast-1
      s3forcepathstyle: false
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2026-04-22
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h    # 30 days
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: s3
```

**`alertmanager/alertmanager.yml`**
```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: '${SMTP_HOST}:587'
  smtp_from: 'alerts@wanbrain.com'
  smtp_auth_username: '${SMTP_USER}'
  smtp_auth_password: '${SMTP_PASS}'

route:
  receiver: p2-telegram
  group_by: [alertname, product, severity]
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: [severity="High"]
      receiver: p1-telegram-email
      group_wait: 0s
      repeat_interval: 30m
    - matchers: [severity="Medium"]
      receiver: p2-telegram
      active_time_intervals: [work-hours]
    - matchers: [severity="Low"]
      receiver: low-digest
      group_interval: 24h
      repeat_interval: 24h

time_intervals:
  - name: work-hours
    time_intervals:
      - times: [{ start_time: '09:00', end_time: '21:00' }]
        weekdays: ['monday:sunday']
        location: Asia/Taipei

receivers:
  - name: p1-telegram-email
    telegram_configs:
      - bot_token: '${TG_BOT_TOKEN}'
        chat_id: ${TG_CHAT_P1}
        parse_mode: MarkdownV2
        message: |
          *🚨 High {{ .GroupLabels.alertname }}*
          Product: {{ .GroupLabels.product }}
          {{ range .Alerts }}- {{ .Annotations.summary }}{{ end }}
          Runbook: {{ .CommonAnnotations.runbook_url }}
    email_configs:
      - to: 'oncall@wanbrain.com'
        send_resolved: true

  - name: p2-telegram
    telegram_configs:
      - bot_token: '${TG_BOT_TOKEN}'
        chat_id: ${TG_CHAT_P2}
        parse_mode: MarkdownV2

  - name: low-digest
    email_configs:
      - to: 'reports@wanbrain.com'
        send_resolved: false
```

**`prometheus/rules/system.yml`**
```yaml
groups:
  - name: system
    interval: 30s
    rules:
      - alert: HostHighCPU
        expr: 100 - (avg by (instance, product) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 10m
        labels: { severity: Medium }
        annotations:
          summary: "{{ $labels.instance }} CPU > 85% 10min"
          runbook_url: "https://github.com/<you>/ppc-observability/blob/main/runbooks/high-cpu.md"

      - alert: HostDiskLow
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 10
        for: 5m
        labels: { severity: High }
        annotations:
          summary: "{{ $labels.instance }} 磁碟剩 < 10%"
          runbook_url: "..."

      - alert: HostOOM
        expr: node_vmstat_oom_kill > 0
        for: 1m
        labels: { severity: High }
        annotations: { summary: "{{ $labels.instance }} OOM killer 啟動" }

      - alert: SystemdUnitDown
        expr: node_systemd_unit_state{state="failed"} == 1
        for: 5m
        labels: { severity: High }
        annotations: { summary: "{{ $labels.name }} systemd failed on {{ $labels.instance }}" }
```

**`prometheus/rules/app.yml`**
```yaml
groups:
  - name: app
    interval: 30s
    rules:
      - alert: BackendDown
        expr: up{job="ppclub-backend"} == 0
        for: 2m
        labels: { severity: High, product: ppclub }
        annotations:
          summary: "PPClub backend 無法 scrape > 2min"
          runbook_url: "..."

      - alert: High5xxRate
        expr: |
          sum by (product) (rate(http_requests_total{status=~"5..",product="ppclub"}[5m]))
          /
          sum by (product) (rate(http_requests_total{product="ppclub"}[5m])) > 0.05
        for: 5m
        labels: { severity: Medium, product: ppclub }
        annotations: { summary: "PPClub 5xx 比率 > 5% 持續 5min" }

      - alert: Critical5xxRate
        expr: |
          sum by (product) (rate(http_requests_total{status=~"5..",product="ppclub"}[5m]))
          /
          sum by (product) (rate(http_requests_total{product="ppclub"}[5m])) > 0.10
        for: 2m
        labels: { severity: High, product: ppclub }

      - alert: LatencyP99High
        expr: histogram_quantile(0.99, sum by (le, product) (rate(http_request_duration_seconds_bucket{product="ppclub"}[5m]))) > 3
        for: 10m
        labels: { severity: Medium, product: ppclub }

      - alert: UnhandledException
        expr: increase(ppc_unhandled_exception_total[5m]) > 3
        for: 0m
        labels: { severity: Medium, product: ppclub }
```

**`prometheus/rules/business.yml`**
```yaml
groups:
  - name: business
    interval: 1m
    rules:
      - alert: ZeroPayment1Hour
        expr: |
          (hour() >= 9 and hour() <= 22)
          and
          sum(increase(ppc_payment_success_total[1h])) == 0
        for: 5m
        labels: { severity: High, product: ppclub }
        annotations: { summary: "白天連續 1hr 零成功付款" }

      - alert: RefundSurge
        expr: |
          sum(increase(ppc_refund_total[1h]))
          > 3 * avg_over_time(sum(increase(ppc_refund_total[1h]))[7d:1h])
        for: 10m
        labels: { severity: Low, product: ppclub }
        annotations: { summary: "退款 rate 是 7 天均值 3x" }

      - alert: ExternalApiDown
        expr: probe_success{job="blackbox"} == 0
        for: 5m
        labels: { severity: High }
        annotations: { summary: "{{ $labels.target }} 外部 API 不通" }
```

**`prometheus/rules/deadman.yml`**
```yaml
groups:
  - name: deadman
    interval: 1m
    rules:
      - alert: SchedulerNoHeartbeat
        expr: time() - ppc_scheduled_job_last_run_timestamp > 3600
        for: 5m
        labels: { severity: High, product: ppclub }
        annotations: { summary: "scheduler {{ $labels.job }} 1hr 無心跳" }

      - alert: PrometheusSelfStale
        # 中央 Prom 自己停了要靠 UptimeRobot 抓；這條是備援
        expr: time() - prometheus_tsdb_head_max_time_seconds > 300
        for: 1m
        labels: { severity: High }
```

### 6.4 建置 SOP

1. **建 EC2 + IAM + S3**（Terraform 或手動都可；若手動請記錄每步）
2. **SSH 進機器、安裝 Docker**
   ```bash
   sudo apt update && sudo apt install -y docker.io docker-compose-plugin
   sudo usermod -aG docker ubuntu && exec su -l ubuntu
   ```
3. **Clone 新 repo**，`cp .env.example .env`、填入 secrets
4. **啟動**：`docker compose up -d`
5. **Cloudflare Dashboard 設 tunnel 路由**（對應三個 hostname + Access policy）
   - `grafana.wanbrain.com` → `http://grafana:3000`，Access policy 限 allowed emails
   - `prom-push.wanbrain.com` → `http://prometheus:9090`，Access policy 限 service token
   - `loki-push.wanbrain.com` → `http://loki:3100`，Access policy 限 service token
6. **登入 Grafana**（走 CF Access → Google → 自動進入）→ 確認 datasource 已 provision
7. **匯入 dashboard**（先從 grafana.com ID 1860、18739 匯入，export JSON 丟 git）
8. **測試 alert**
   ```bash
   # 手動觸發測試 alert
   curl -H 'Content-Type: application/json' -d '[{
     "labels": {"alertname":"TestP1","severity":"High"},
     "annotations":{"summary":"test"}
   }]' http://127.0.0.1:9093/api/v2/alerts
   ```
   → Telegram 應在 10 秒內收到

**Phase 1 驗收**
- `grafana.wanbrain.com` 能打開 → 被導向 CF Access → 過 Google → 自動進入 Grafana（不顯示 Grafana 自己的 login 表單）
- 用 `curl https://grafana.wanbrain.com` 無 auth 會被 CF Access 擋（拿到 redirect to login）
- 手動 alert 測試能收到 Telegram
- Prometheus targets page 只有自己（還沒有 agent push）
- Loki S3 bucket（`skyeye-loki-chunks`）裡有 `index_*` 和 `fake_*` object 產生
- 每日 heartbeat email 能收到（驗證 Gmail SMTP）

---

## 7. Phase 2 — PPClub Instrument（2 天，小心不中斷）

### 7.1 Backend /metrics endpoint

**install 時的安全考量**
- PPClub backend 跑在 venv：`/home/ubuntu/PPClub/backend/.venv`
- 裝套件**不重啟服務**即可完成
- 改 code 後 `systemctl restart ppclub-backend.service`，停機約 3–5 秒，Caddy 會 retry

**步驟**
```bash
# 在 PPClub EC2
cd /home/ubuntu/PPClub/backend
source .venv/bin/activate
pip install prometheus-fastapi-instrumentator
pip freeze > requirements.txt   # 鎖版本
```

`app/main.py` patch（加在 `app = FastAPI(...)` 之後、`include_router` 之前）：
```python
from prometheus_fastapi_instrumentator import Instrumentator

Instrumentator(
    excluded_handlers=["/metrics", "/api/health"],
    should_group_status_codes=False,      # 保留 200/201/401/404 細分
    should_ignore_untemplated=True,        # /events/{slug} 聚合，避免 cardinality 爆炸
).instrument(app).expose(app, include_in_schema=False)
```

**部署（低風險步驟）**
```bash
# 先本地驗證 code 通
python -c "from app.main import app"

# 熱載入測試（不影響 prod）
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8091 &
curl -s http://127.0.0.1:8091/metrics | head -20
kill %1

# 正式切換
sudo systemctl restart ppclub-backend.service
sleep 2
curl -s http://127.0.0.1:8090/metrics | head -5   # 應回 metrics
```

### 7.2 業務 Counter（根據 code 盤點）

| Hook | 檔案:行 | Metric |
|------|--------|--------|
| 付款建立 | `app/newebpay.py` create_payment 結尾 | `ppc_payment_created_total{method, status}` |
| 付款成功 callback | `app/routers_v2/payments.py` | `ppc_payment_success_total{method}` |
| 退款 | `app/services/refund.py` | `ppc_refund_total{reason, result}` |
| 活動報名 | `app/routers_v2/openplay.py` signup endpoint | `ppc_event_signup_total{result}` |
| Credit 儲值 | `app/routers/credit.py` | `ppc_credit_topup_total{amount_bucket}` |
| 註冊 | `app/routers_v2/auth.py` | `ppc_signup_total{method}` |
| 手機驗證 | `app/routers_v2/phone.py` | `ppc_phone_verify_total{result}` |
| 外部 API latency | `app/newebpay.py`, `app/hengfu_hardware.py` | `ppc_external_api_duration_seconds{api, endpoint}`（histogram） |
| 排程心跳 | `app/scheduler.py` 每個 job 結尾 | `ppc_scheduled_job_last_run_timestamp{job}`（gauge `.set_to_current_time()`） |
| Unhandled exception | `app/main.py:94-100` global_exception_handler | `ppc_unhandled_exception_total{path, exc_type}` |

**實作建議**：新建 `app/metrics.py` 集中定義所有 counter / histogram / gauge，避免散落各檔案：
```python
from prometheus_client import Counter, Histogram, Gauge

payment_created = Counter("ppc_payment_created_total", "", ["method", "status"])
payment_success = Counter("ppc_payment_success_total", "", ["method"])
refund = Counter("ppc_refund_total", "", ["reason", "result"])
event_signup = Counter("ppc_event_signup_total", "", ["result"])
credit_topup = Counter("ppc_credit_topup_total", "", ["amount_bucket"])
signup = Counter("ppc_signup_total", "", ["method"])
phone_verify = Counter("ppc_phone_verify_total", "", ["result"])

external_api_latency = Histogram(
    "ppc_external_api_duration_seconds", "",
    ["api", "endpoint"],
    buckets=[0.1, 0.3, 0.5, 1, 2, 5, 10]
)

scheduler_last_run = Gauge(
    "ppc_scheduled_job_last_run_timestamp", "",
    ["job"]
)

unhandled_exc = Counter("ppc_unhandled_exception_total", "", ["path", "exc_type"])
```

**Label cardinality 守則**（寫進 README，守好不然會爆 Prometheus）：
- ❌ 不可當 label：`user_id`, `email`, `phone`, `order_id`, `session_id`, `url`（含參數）
- ✅ 可以當 label：`method`（atm/credit/linepay）、`result`（ok/failed/timeout）、`endpoint`（NewebPay / Hengfu / Google）

### 7.3 PPClub EC2 Alloy 安裝

重寫版的 `agents/alloy/setup.sh`（相較舊版，config 模板化、錯誤訊息友善、參數可覆寫）：
```bash
sudo PRODUCT=ppclub \
     SERVER_ID=ppclub-prod \
     SCRAPE_METRICS=http://localhost:8090/metrics \
     JOURNAL_UNITS=ppclub-backend.service,caddy.service \
     CF_CLIENT_ID=xxx.access \
     CF_CLIENT_SECRET=yyy \
     bash agents/alloy/setup.sh
```

agent config 產生後要注入 **PII scrub pipeline**：
```alloy
loki.process "scrub_pii" {
  // 姓名（中文 2-4 字後接冒號或空格）
  stage.replace {
    expression = "(姓名[：:=]\\s*)[^\\s,}]+"
    replace    = "$1[REDACTED_NAME]"
  }
  // 手機（09xx-xxx-xxx or 09xxxxxxxx）
  stage.replace {
    expression = "09\\d{2}[-]?\\d{3}[-]?\\d{3}"
    replace    = "[REDACTED_PHONE]"
  }
  // Email
  stage.replace {
    expression = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
    replace    = "[REDACTED_EMAIL]"
  }
  // NewebPay Email 欄位（已知格式：'Email': 'xxx'）
  stage.replace {
    expression = "('Email'\\s*:\\s*')[^']+(')"
    replace    = "$1[REDACTED]$2"
  }
  forward_to = [loki.write.guardian.receiver]
}
```

**同機 enyoung-server 順便包進來**：
Alloy 可以同時 scrape 多個本機 target，`config.alloy` 加第二個 `prometheus.scrape` block 指向 `localhost:8080/metrics`（如果 enyoung 有 /metrics；沒有就只收 journalctl）。

### 7.4 Dashboard 建置

- 匯入 ID 1860（node-exporter-full）→ export JSON 存 `grafana/dashboards/node.json`
- 匯入 ID 18739（FastAPI）→ `grafana/dashboards/fastapi.json`
- 自建 `ppclub-business.json`：
  - 每小時付款成功 / 失敗 heatmap
  - 每日退款數趨勢
  - 活動報名漏斗（訪問→報名→付款）
  - Credit 儲值 pie（金額分桶）
  - 外部 API p99 latency（NewebPay / Hengfu）
- 自建 `overview.json`：多產品 SLO、up/down、error budget

**Dashboard git 紀律**（寫進 README）：
> UI 可以自由編輯，但**不按儲存按鈕**。滿意後用 Share → Export → Save to file，覆蓋 `grafana/dashboards/*.json` 進 git。Provisioned dashboard 重啟就會被 git 版本覆蓋。

**Phase 2 驗收**
- `curl localhost:8090/metrics` 回 Prom 格式
- Grafana 查 `rate(http_requests_total[5m])` 有數據
- `systemctl stop ppclub-backend` → 2 min 內 Telegram High 收到 BackendDown
- LogQL `{product="ppclub"} |= "refund"` 能撈出退款 log，且姓名/手機/email 已被遮

---

## 8. Phase 3 — Multi-product + 強化（2 天）

### 8.1 enyoung 與未來產品
- 每台新機跑 `agents/alloy/setup.sh`，差別只在 `PRODUCT=enyoung` / `SERVER_ID=...`
- Prometheus 不用改 config（remote-write 模式，中央被動接收）
- Grafana dashboard 加 `product` variable（dropdown），同 dashboard 可切產品看

### 8.2 Caddy Exporter
- Caddy 2.x 內建 Prometheus exporter，在 `Caddyfile` 加：
  ```
  {
    servers {
      metrics
    }
  }
  ```
- Alloy 加 scrape target：`http://localhost:2019/metrics`（Caddy admin port）
- 新 dashboard：邊緣層 2xx/4xx/5xx vs. 應用層 /metrics 交叉驗證

### 8.3 Blackbox Exporter（外部依賴 probe）

在 monitoring-prod 加 blackbox container：
```yaml
blackbox:
  image: prom/blackbox-exporter:latest
  restart: unless-stopped
  volumes:
    - ./blackbox/config.yml:/etc/blackbox_exporter/config.yml:ro
  ports:
    - "127.0.0.1:9115:9115"
```

Prometheus 加 scrape job：
```yaml
- job_name: blackbox
  metrics_path: /probe
  params:
    module: [http_2xx]
  static_configs:
    - targets:
        - https://core.newebpay.com/API/QueryTradeInfo
        - https://server.hengfu-i.com/
        - https://accounts.google.com/o/oauth2/v2/auth
  relabel_configs:
    - source_labels: [__address__]
      target_label:  __param_target
    - source_labels: [__param_target]
      target_label:  target
    - target_label: __address__
      replacement: blackbox:9115
```

→ `probe_success == 0` 就觸發 High ExternalApiDown alert（已在 `business.yml`）

### 8.4 Prometheus Snapshot 備份（可選）

`scripts/backup-prometheus.sh`（cron 每日 03:00）：
```bash
#!/usr/bin/env bash
set -euo pipefail
SNAP_ID=$(curl -s -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot | jq -r .data.name)
SNAP_DIR="/var/lib/docker/volumes/ppc-observability_prometheus_data/_data/snapshots/${SNAP_ID}"
DATE=$(date -u +%Y-%m-%d)
aws s3 sync "$SNAP_DIR" "s3://skyeye-prometheus-snapshots/${DATE}/"
rm -rf "$SNAP_DIR"
```

Lifecycle 規則 30 天 expire（與 Prometheus in-place retention 對齊）。

### 8.5 Runbook 建立

每條 alert 必須有 `runbook_url`。`runbooks/_template.md`：
```markdown
# <Alert Name>
## 症狀
## 常見根因
## 立即處置（可照做的步驟）
## 驗證已恢復
## 事後追查（可選）
```

先寫 5 條最常觸發的：backend-down、payment-zero、disk-full、external-api-down、high-5xx。

**Phase 3 驗收**
- 多個 product 都能在 Grafana 切換
- 關閉 NewebPay DNS 解析測試（或設假 target）→ High alert 觸發
- Scheduler 停 1 hr → deadman High 觸發
- Runbook URL 在 Telegram 訊息中能點開

---

## 9. Phase 4 — 未來（不現在做）

當以下需求出現再加：
- **Distributed tracing**（Tempo + OpenTelemetry）— 拆微服務後
- **Synthetic user flow**（k6 跑「登入→選活動→付款→確認」）— 當人工測試頻繁
- **RUM（Grafana Faro）**— 想看真實用戶 web vitals
- **SLO / Error budget** dashboard — 當團隊開始用 SRE 做事
- **PagerDuty / oncall 輪值** — 團隊人數 > 3 再考慮

---

## 10. Guardian → 新系統 Cutover SOP

目標：零 downtime、可回滾。

1. **新機建好、所有 Phase 1 驗收通過**
2. **Cloudflare DNS 先不改**，讓 `grafana.wanbrain.com` 暫指舊 Guardian
3. 在 PPClub EC2 **並行裝** Alloy（舊 Guardian 的 Promtail 還在跑，不衝突）
4. 確認新 Grafana 收到 PPClub metrics + logs（對比舊 Guardian）
5. **切換 DNS**：`grafana.wanbrain.com` 指向新 monitoring-prod tunnel
6. **觀察 24 hr**
7. 舊 Guardian 停掉：
   ```bash
   cd /home/ubuntu/go/src/Guardian
   docker compose down
   ```
   目錄保留 read-only，不刪 `.git`（萬一要回滾）
8. 舊 Promtail 在 PPClub EC2 停掉（如果有跑）

**回滾路徑**：DNS 切回、舊 Guardian `docker compose up -d`。

---

## 11. 成本估算（Tokyo 區）

| 項目 | 月費 |
|------|------|
| EC2 t4g.medium on-demand | $24 |
| EC2 t4g.medium 1-yr RI | **$15** |
| EBS 40 GB gp3 | $3.20 |
| S3 Loki chunks（~5 GB / 30 天 + request） | $0.50 |
| S3 Prometheus snapshot（~1 GB / 30 天） | $0.10 |
| Cloudflare Tunnel | $0 |
| UptimeRobot | $0 |
| Sentry 免費 tier | $0 |
| Telegram Bot | $0 |
| **合計（RI）** | **~$19/月** |

多加一個 product 不會增加中央成本（agent 在被監控機上跑）。

---

## 12. 風險與緩解

| 風險 | 影響 | 緩解 |
|------|------|------|
| Monitoring 自己掛 | 全盲 | UptimeRobot 外部 probe + 收 Telegram High |
| Cloudflare tunnel 斷 | Agent push 失敗 | Alloy 本機 buffer 預設 2hr；超過會 drop |
| Gmail 帳號遭 Google 風控鎖住 | **告警送不出來** | Daily heartbeat email（§13.2）；另配一個備用通道（Telegram 已是 High，email 只是備份） |
| S3 bucket 遭誤刪 | 過去 log 遺失 | S3 versioning 或 bucket policy 禁 delete（運維高階操作才能關） |
| PII regex miss | log 洩漏 | Code review 新 logger 時檢查；每季 sample log 掃描 |
| Prometheus 高 cardinality 爆記憶體 | OOM | `.env` 設 memory limit；新 metric code review 走 label cardinality checklist |
| Ubuntu 20.04 EOL（PPClub EC2） | 無 security patch | 排期 Q3 升級 22.04 / 24.04，不影響 monitoring 建置 |
| Grafana UI 改了沒進 git | 重啟消失 | 每週跑 `scripts/grafana-export-dashboards.sh` 掃差異，CI 檢查 |
| Log 量爆炸（某個 bug 狂 log） | S3 吃錢 / Loki query 慢 | Loki `limits_config` 加 `ingestion_rate_mb` 上限；超量直接丟 |

---

## 13. 決策紀錄（2026-04-22 拍板）

以下六項均已拍板，實作時依此執行：

| # | 項目 | 決策 |
|---|------|------|
| 1 | Repo 名稱 | **`SkyEye`**（本 repo） |
| 2 | Grafana 入口 | **Cloudflare Access 前置 + `auth.proxy` trust header**（見 §13.1） |
| 3 | Prometheus snapshot → S3 | **要做**（每日 03:00 cron） |
| 4 | Retention | **Prometheus 30 天 / Loki 30 天 / Snapshot 30 天**（三個對齊） |
| 5 | SMTP | **Gmail SMTP**（先上，見 §13.2 風險，量大再遷 SES） |
| 6 | Secrets 管理 | **`.env` 檔放 monitoring-prod 機器**（見 §13.3 守則） |

---

### 13.1 Grafana 入口：Cloudflare Access 前置 vs. 直接 Google OAuth

| 面向 | A. Grafana 自身 Google OAuth | B. **Cloudflare Access 前置（採用）** |
|------|-----------------------------|--------------------------------------|
| 用戶流程 | 打開 URL → Grafana login 頁 → 點 Google | 打開 URL → CF Access 跳 Google → 通過即進入 Grafana |
| 登入次數 | 1 次 | 1 次（CF Access SSO；Grafana 用 `auth.proxy` 信任 header 自動登入） |
| 攻擊面 | Grafana login 頁**暴露公網**，任何人可打 | 未過 CF Access **完全看不到 Grafana**（連 login 頁） |
| CVE 緩衝 | 若 Grafana 有 0-day（如 CVE-2021-43798 path traversal），直接受害 | CF Access 先擋，Grafana 不對外 |
| MFA / device posture | Grafana 需另裝 plugin | CF Access 原生支援 |
| Audit log | Grafana 自己的 log | CF Access dashboard 有完整登入紀錄（誰、何時、哪個 IP） |
| 故障情境 | Grafana 掛才不能登 | CF Access 掛也不能登（但 CF 可用性 > Grafana） |
| 設定複雜度 | 中（填 Google OAuth client） | 中高（CF Access app + Grafana `auth.proxy` config） |
| 費用 | 免費 | 免費（CF Zero Trust 免費 tier 50 users） |

**為什麼選 B**：你是小團隊 / 單人使用，登入次數極低，但 Grafana 內有 PII 和業務資料，不能讓它的 login page 公開被掃。CF Access 同 Google OAuth 本質一樣，但把認證邊界從「Grafana 本身」推到「Cloudflare edge」，換來多一層防禦。

**實作重點**（寫進 `grafana/provisioning/` 與 Cloudflare dashboard）：
```ini
# grafana.ini（透過 env var 注入 docker-compose）
[auth]
disable_login_form = true              # 不再顯示帳密登入
disable_signout_menu = false

[auth.proxy]
enabled = true
header_name = Cf-Access-Authenticated-User-Email
header_property = email
auto_sign_up = true
whitelist = 127.0.0.1, 172.16.0.0/12   # 僅信任 cloudflared container 的來源
```
```
Cloudflare Zero Trust → Access → Applications：
  Application: grafana.wanbrain.com
  Policy: allow emails = [your@gmail.com, teammate@...]
  Identity provider: Google
  Session duration: 24h
```

**風險**：本機 admin 帳號仍可透過 `/login` path bypass（`disable_login_form` 只是不顯示 UI 不是禁 API），所以：
- `GF_SECURITY_ADMIN_PASSWORD` 要 32+ 字隨機
- Grafana port 只 bind `127.0.0.1`，外部只能走 cloudflared tunnel 進來
- 開啟 `GF_AUTH_DISABLE_LOGIN_FORM=true` + `GF_AUTH_BASIC_ENABLED=false` 禁用 basic auth API

---

### 13.2 SMTP 來源：Gmail vs. SES / Resend / SendGrid

| 面向 | **Gmail SMTP（採用）** | AWS SES | Resend | SendGrid |
|------|----------------------|---------|--------|----------|
| 設定難度 | 最低（app password 一條） | 中（驗證 domain + 脫 sandbox 要等 1-2 天） | 低 | 低 |
| 每日送件上限 | **個人 500 / Workspace 2000** | 無實質上限 | 3000/月免費 | 100/天免費（新政策） |
| 發件地址 | **只能是 Gmail 本身或 Workspace alias** | 任何已驗證 domain（`alerts@wanbrain.com`） | 同 SES | 同 SES |
| Deliverability | 普通（從 `@gmail.com` 發告警容易被收件端當成無關通知） | 高（domain 正確設 SPF/DKIM/DMARC） | 高 | 高 |
| 被風控鎖帳號風險 | **存在**（Google 視大量自動信為濫用） | 不會 | 不會 | 不會 |
| App Password 取消風險 | Google 已逐步收緊；Workspace 帳號需 admin 開啟 | 無關 | 無關 | 無關 |
| 成本 | $0 | ~$0.10 / 千封 | 免費（3k 內） | 免費（100/天內） |
| 告警可靠性 | **中**：若 Gmail 帳號異常，告警也送不出 | 高 | 高 | 高 |

**為什麼接受 Gmail 先上**：告警量小（High 一天應該 < 10 封；Low digest 一天 1 封），500 封/天綽綽有餘；對新建 infra 來說降低初期複雜度優先。

**但要接受這些取捨**：
1. 發信地址會是 `your@gmail.com` 或 Workspace 的 `alerts@wanbrain.com`（後者較好）
2. 如果 Gmail 帳號本身遭鎖，你會**收不到告警**——要設「heartbeat email 每日驗證」
3. 以後量大或需要從 `alerts@wanbrain.com` 發信，遷移 SES

**Gmail SMTP 實作**：
```bash
# 前置：開啟 Google 2FA → 生成 App Password
# https://myaccount.google.com/apppasswords
# 產生 16 字無空白密碼，存入 .env

# .env
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your@gmail.com           # 或 alerts@wanbrain.com（若有 Workspace）
SMTP_PASS=<16-char app password>
SMTP_FROM=your@gmail.com           # 必須 == SMTP_USER
```

`alertmanager.yml` 相應欄位：
```yaml
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: '${SMTP_FROM}'
  smtp_auth_username: '${SMTP_USER}'
  smtp_auth_password: '${SMTP_PASS}'
  smtp_require_tls: true
```

**Heartbeat 驗證機制**（補進 Phase 3 runbook）：
- 每天 09:00 發一封「monitoring heartbeat」到你的主信箱
- 若連續 2 天沒收到 → 代表 Gmail SMTP 或整個監控掛了
- 實作：加一個 `DailyHeartbeat` alert，always firing，走 Low digest
  ```yaml
  - alert: DailyHeartbeat
    expr: vector(1)
    for: 0s
    labels: { severity: Low }
    annotations: { summary: "monitoring-prod is alive at {{ $value }}" }
  ```

**未來遷移 SES 的 trigger 條件**（寫進 runbook）：
- 告警量 > 300 封/天
- 想從 `alerts@wanbrain.com` 發信提升 deliverability
- Google 加強 app password 限制

---

### 13.3 Secrets 在 `.env` 的安全守則（採用此方式的前提）

把 secrets 放機器 `.env` 是最簡方案，但要守住幾條底線，否則形同裸奔：

**必做清單**
1. **`.env` 檔絕對不進 git**
   - `.gitignore` 第一行加 `.env`
   - Pre-commit hook 用 `git diff --cached | grep -E "TOKEN|SECRET|PASSWORD"` 攔截
2. **檔案權限 0600**
   ```bash
   chmod 600 /home/ubuntu/SkyEye/.env
   chown ubuntu:ubuntu /home/ubuntu/SkyEye/.env
   ```
3. **EBS at-rest encryption 啟用**（EC2 建立時勾選）
4. **禁止在 shell history / CI log 中 echo secrets**
   - 不要 `cat .env` 然後 copy
   - `docker compose` 讀 env 是安全的（不會印出）
5. **定期輪換**（每 180 天）
   - Telegram bot token：@BotFather `/revoke` → 新 token
   - Google OAuth secret：Google Console 重新生成
   - CF Access service token：Cloudflare Zero Trust rotate
   - Gmail app password：Google account 刪除舊的發新的
6. **備份 `.env` 到 1Password / Bitwarden**（萬一機器 EBS 掛了）

**升級路徑**（若哪天覺得不夠安全）
- AWS SSM Parameter Store（免費 standard tier）：`docker compose` 起來前用 `aws ssm get-parameters-by-path` 匯出成 `.env`
- AWS Secrets Manager（$0.40/secret/月）：內建 rotation
- 這條路徑不用改 app code，只改 bootstrap script

**當前不採用 SSM / Secrets Manager 的理由**：單機、secrets 少、團隊小，.env 可追溯性已足夠；先跑起來再說。

---

## 14. 時程彙總

| Phase | 人時 | Depends on | 可平行 |
|-------|------|-----------|-------|
| Phase 0 | 1 天 | — | 與 Phase 1 並行 |
| Phase 1 | 3 天 | AWS 帳號、Cloudflare tunnel 已有 | — |
| Phase 2 | 2 天 | Phase 1 完成 | — |
| Phase 3 | 2 天 | Phase 2 完成 | 部分與 Phase 2 並行 |
| Cutover | 0.5 天 | Phase 2 完成、24hr 觀察 | — |

**總計約 8 天人時**（不含觀察期）。

---

## 15. 參考資源

- [prometheus-fastapi-instrumentator](https://github.com/trallnag/prometheus-fastapi-instrumentator)
- [Grafana Alloy docs](https://grafana.com/docs/alloy/latest/)
- [Loki S3 best practice](https://grafana.com/docs/loki/latest/operations/storage/)
- [Alertmanager config reference](https://prometheus.io/docs/alerting/latest/configuration/)
- [Cloudflare Tunnel + Service Token](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- Dashboard IDs：1860 (node)、18739 (FastAPI)、14802 (Caddy)
- [Loki best practices: label cardinality](https://grafana.com/docs/loki/latest/best-practices/)

---

## Appendix A — PII Scrub Regex 快查

| 資料 | Regex | 範例 match |
|------|-------|-----------|
| 手機 | `09\d{2}[-]?\d{3}[-]?\d{3}` | `0912345678`, `0912-345-678` |
| Email | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` | `user@example.com` |
| 姓名 key | `('?姓名'?\s*[:：=]\s*)[^\s,}]+` | `姓名: 王小明`, `'Name': '王小明'` |
| NewebPay Email key | `('Email'\s*:\s*')[^']+(')` | `'Email': 'x@y.com'` |
| 金額（可選） | `('Amt'\s*:\s*')\d+(')` | `'Amt': '750'` |

---

## Appendix B — Alloy config.alloy 模板骨架

```alloy
// Generated by agents/alloy/setup.sh for ${PRODUCT} / ${SERVER_ID}

prometheus.exporter.unix "node" {
  disable_collectors = ["arp","btrfs","entropy","nfs","nfsd","nvme","xfs","zfs"]
}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.node.targets
  forward_to      = [prometheus.remote_write.central.receiver]
  scrape_interval = "15s"
  job_name        = "node-exporter"
}

prometheus.scrape "app" {
  targets         = [{ __address__ = "localhost:${APP_METRICS_PORT}" }]
  forward_to      = [prometheus.remote_write.central.receiver]
  scrape_interval = "15s"
  job_name        = "${PRODUCT}-backend"
}

prometheus.remote_write "central" {
  endpoint {
    url     = "${PROM_PUSH_URL}"
    headers = {
      "CF-Access-Client-Id"     = "${CF_CLIENT_ID}",
      "CF-Access-Client-Secret" = "${CF_CLIENT_SECRET}",
    }
  }
  external_labels = {
    product   = "${PRODUCT}",
    server_id = "${SERVER_ID}",
  }
}

loki.source.journal "system" {
  matches    = "${JOURNAL_MATCHES}"   // e.g. "_SYSTEMD_UNIT=ppclub-backend.service"
  forward_to = [loki.process.scrub_pii.receiver]
  labels     = { product = "${PRODUCT}", server_id = "${SERVER_ID}" }
}

loki.process "scrub_pii" {
  stage.replace { expression = "09\\d{2}[-]?\\d{3}[-]?\\d{3}",                           replace = "[PHONE]" }
  stage.replace { expression = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",         replace = "[EMAIL]" }
  stage.replace { expression = "('?姓名'?\\s*[:：=]\\s*)[^\\s,}]+",                        replace = "$1[NAME]" }
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  endpoint {
    url     = "${LOKI_PUSH_URL}"
    headers = {
      "CF-Access-Client-Id"     = "${CF_CLIENT_ID}",
      "CF-Access-Client-Secret" = "${CF_CLIENT_SECRET}",
    }
  }
}
```

---

## Appendix C — PPClub 銜接點清單（從 code 盤點）

- systemd unit：`ppclub-backend.service`
- uvicorn 綁定：`127.0.0.1:8090`
- Log：`journalctl -u ppclub-backend.service`（`--unit=ppclub-backend.service`）
- Frontend：`/home/ubuntu/PPClub/frontend/dist`，由 **Caddy** serve（非 nginx）
- DB：SQLite `/home/ubuntu/PPClub/backend/ppc.db`（scrape 意義不大，看 query latency 即可）
- 外部依賴：
  - NewebPay：`https://core.newebpay.com/API/*`
  - Hengfu：`https://server.hengfu-i.com/*`
  - Google OAuth：`https://accounts.google.com/*`
- Code 切入點：
  - `app/main.py:46` — FastAPI app 物件
  - `app/main.py:94-100` — global exception handler（掛 unhandled_exception counter）
  - `app/newebpay.py` — payment create / refund / query
  - `app/services/refund.py` — refund service
  - `app/routers_v2/payments.py` — NewebPay callback
  - `app/routers_v2/openplay.py` — 活動報名
  - `app/routers/credit.py` — credit 儲值
  - `app/routers_v2/auth.py` — 註冊
  - `app/routers_v2/phone.py` — 手機驗證
  - `app/scheduler.py` — 排程任務（掛 heartbeat gauge）
  - `app/hengfu_hardware.py` — Hengfu API client（external latency histogram）
