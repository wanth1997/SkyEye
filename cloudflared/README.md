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

## 驗證

```bash
# 從外部（例如你手機 4G 網路）
curl -v https://grafana.wanbrain.com
# 應該看到 302 redirect 到 Cloudflare Access login

# 過完 Google OAuth → 應該直接進 Grafana（不顯示 Grafana login 表單）
```
