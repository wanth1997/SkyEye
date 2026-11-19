# cloudflared/

## 檔案

- `config.yml` — tunnel ingress rules（進 git）
- `credentials.json` — tunnel secret（**不進 git**）

## 一次性建 tunnel 的流程

建議在**你 laptop** 執行（不在這台 EC2），步驟較安全、介面較清楚。

### 1. 裝 cloudflared

```bash
# macOS
brew install cloudflared

# Linux
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
```

### 2. 登入

```bash
cloudflared login
# 會開瀏覽器 → 選 wanbrain.com zone → 授權
# 成功會把 cert.pem 存到 ~/.cloudflared/
```

### 3. 建 tunnel

```bash
cloudflared tunnel create skyeye-monitoring-prod
# 輸出會顯示：
#   Tunnel credentials written to ~/.cloudflared/<UUID>.json
#   Created tunnel skyeye-monitoring-prod with id <UUID>
```

### 4. 建 DNS CNAME（一次一個）

```bash
cloudflared tunnel route dns skyeye-monitoring-prod grafana.wanbrain.com
cloudflared tunnel route dns skyeye-monitoring-prod prom-push.wanbrain.com
cloudflared tunnel route dns skyeye-monitoring-prod loki-push.wanbrain.com
```

### 5. 把 credentials 搬到 server

```bash
# 從 laptop
scp ~/.cloudflared/<UUID>.json ubuntu@<monitoring-prod-ip>:/home/ubuntu/SkyEye/cloudflared/credentials.json

# 在 server
chmod 600 /home/ubuntu/SkyEye/cloudflared/credentials.json
```

### 6. 在 Cloudflare Dashboard 設 Access policy

Zero Trust → Access → Applications → **Add Application** (Self-hosted)：

| Application | Subdomain | Policy（皆不設 path） | Identity provider |
|---|---|---|---|
| SkyEye Grafana | grafana.wanbrain.com | allow email == wanth1997@gmail.com | Google |
| SkyEye Prom push | prom-push.wanbrain.com | `Service Token skyeye-agent-push`、`skyeye-tnauqquant-prod-1-prom-push`、`skyeye-win-runner-push` | Service Auth |
| SkyEye Loki push | loki-push.wanbrain.com | `Service Token skyeye-agent-push`、`skyeye-tnauqquant-prod-1-prom-push`、`skyeye-win-runner-push` | Service Auth |

#### Service Tokens（帳號現況）

以下僅記錄名稱、用途與狀態；**絕不將 secret、client ID 或 AUD 值寫入 Git**。

| Token 名稱 | 用途 | 狀態 |
|---|---|---|
| `skyeye-tnauqquant-prod-1` | tnauqquant prod-1 push | 使用中（到期 2028-08-10） |
| `skyeye-agent-push-win-runner` | Windows host push | 使用中 |
| `Skyeye token` | SkyEye push | 使用中 |
| `skyeye-agent-push` | SkyEye push | Not Seen Yet |
| `learnerllm-agent` | 非 SkyEye（同帳號） | 最後使用 2026-02-23 |

Grafana 不信任任何 email header，只接受 Access 簽發的 JWT（`Cf-Access-Jwt-Assertion`），而且要同時符合 `SkyEye Grafana` 的 AUD tag 與 team domain `wanbrain.cloudflareaccess.com`。這兩個值寫在 `docker-compose.yml` 的 `GF_AUTH_JWT_EXPECT_CLAIMS` 與 `GF_AUTH_JWT_JWK_SET_URL`。它們不是 secret，每個登入中的瀏覽器都拿得到。

- `grafana.wanbrain.com` 只能由這一個 application 涵蓋，destination 不設 path。Grafana 只接受一個 AUD，另外建 path 專用的 application 時，那些路徑的登入會失敗。
- **絕不要刪除並重建 `SkyEye Grafana` application**：重建會產生新的 AUD，而 `docker-compose.yml` 已固定原本的 AUD，直接重建會讓所有人都被擋在外面（若非重建不可，必須先更新 `docker-compose.yml`）。
- Session Duration 設定在 `SkyEye Grafana` 這個 application 上。
- 登入失敗的判讀、rollback 與救回步驟見 [`docs/operations.md`](../docs/operations.md#grafana-sign-in-cloudflare-access-jwt)。

## WAF rule

`prom-push.wanbrain.com` 與 `loki-push.wanbrain.com` 的 Access policy 不設 path 條件，改以 Cloudflare WAF custom rule 限制為 write-only：

- **位置**：`wanbrain.com` zone（Free plan）→ **Security → Security rules**
- **規則名稱**：`skyeye-push-write-only`（Action：`Block`，排在 `whoop-security` 之後，2026-11-19 約 07:37Z 啟用）
- **允許範圍**：僅放行 `POST prom-push.wanbrain.com/api/v1/write` 與 `POST loki-push.wanbrain.com/loki/api/v1/push`；這兩個 host 的其他 HTTP method 或 path 一律攔截。

Expression：

```text
(http.host eq "prom-push.wanbrain.com" and not (http.request.method eq "POST" and http.request.uri.path eq "/api/v1/write"))
or
(http.host eq "loki-push.wanbrain.com" and not (http.request.method eq "POST" and http.request.uri.path eq "/loki/api/v1/push"))
```

### 驗證方式

```bash
# 1. GET → 應回傳 Cloudflare WAF block page（403）
curl -i https://prom-push.wanbrain.com/
curl -i https://loki-push.wanbrain.com/

# 2. POST write path 但不帶 token → 應通過 WAF、被 Cloudflare Access 擋下（403）
curl -i -X POST https://prom-push.wanbrain.com/api/v1/write
curl -i -X POST https://loki-push.wanbrain.com/loki/api/v1/push
```

3. 帶合法 service token 的 agent 應持續回傳 `204`，在 Grafana / Prometheus 確認各遠端 agent freshness 正常更新。

### Rollback

在 Cloudflare Dashboard（**Security → Security rules**）將 `skyeye-push-write-only` 的 **Status** 改為 **Disabled**。

## 驗證

```bash
# 從外部（例如你手機 4G 網路）
curl -v https://grafana.wanbrain.com
# 應該看到 302 redirect 到 Cloudflare Access login

# 過完 Google OAuth → 應該直接進 Grafana（不顯示 Grafana login 表單）
```
