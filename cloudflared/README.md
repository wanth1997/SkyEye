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

| Application | Subdomain | Policy | Identity provider |
|---|---|---|---|
| SkyEye Grafana | grafana.wanbrain.com | allow email == wanth1997@gmail.com | Google |
| SkyEye Prom push | prom-push.wanbrain.com | Service Token == skyeye-agent-push | (service auth) |
| SkyEye Loki push | loki-push.wanbrain.com | Service Token == skyeye-agent-push | (service auth) |

Grafana 不信任任何 email header，只接受 Access 簽發的 JWT（`Cf-Access-Jwt-Assertion`），而且要同時符合 `SkyEye Grafana` 的 AUD tag 與 team domain `wanbrain.cloudflareaccess.com`。這兩個值寫在 `docker-compose.yml` 的 `GF_AUTH_JWT_EXPECT_CLAIMS` 與 `GF_AUTH_JWT_JWK_SET_URL`。它們不是 secret，每個登入中的瀏覽器都拿得到。

- `grafana.wanbrain.com` 只能由這一個 application 涵蓋，destination 不設 path。Grafana 只接受一個 AUD，另外建 path 專用的 application 時，那些路徑的登入會失敗。
- 重建這個 application 會換新的 AUD。要重建時，先改 `docker-compose.yml`，否則所有人都會被擋在外面。
- 登入失敗的判讀、rollback 與救回步驟見 [`docs/operations.md`](../docs/operations.md#grafana-sign-in-cloudflare-access-jwt)。

## 驗證

```bash
# 從外部（例如你手機 4G 網路）
curl -v https://grafana.wanbrain.com
# 應該看到 302 redirect 到 Cloudflare Access login

# 過完 Google OAuth → 應該直接進 Grafana（不顯示 Grafana login 表單）
```
