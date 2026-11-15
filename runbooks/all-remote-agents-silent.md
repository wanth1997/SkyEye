# `AllRemoteAgentsSilent`

目前是 shadow（`notification_mode: shadow`），不會送 Telegram，只出現在 Prometheus 的 alerts 頁與 `ALERTS` series。依 AGENTS.md，升級前要先經過 shadow 觀察與 canary。

## Symptoms

```promql
absent(up{job="integrations/unix"} == 1)   # for: 5m, severity High
```

> No remote agent is delivering metrics — check cloudflared and the Access service token

所有遠端 Alloy agent 同時停止送 metrics。中央自己的 node-exporter（`job="monitoring-host"`）不算在內。Windows 主機（`job="integrations/windows"`）也不算：它們各自用專屬的 Access token，不能代表 Linux agents 共用的那一個。通常每台主機的告警也會同時出現；這條告警指出它們的共同原因，不必逐台查。

## Likely causes

1. cloudflared container 停了，或 tunnel connector 跟 Cloudflare 斷線。
2. Cloudflare Access service token `skyeye-agent-push` 過期、被撤銷或輪替了，agent 收到 401/403。
3. `prom-push.wanbrain.com` 的 Access application 或 DNS 被改動。
4. Prometheus 拒絕 remote write（4xx/5xx），例如磁碟滿。
5. Cloudflare 本身故障。

## Immediate actions (copy-paste commands)

在 monitoring-prod 上：

```bash
cd /home/ubuntu/SkyEye
sudo docker compose ps cloudflared prometheus
sudo docker compose logs --since 30m cloudflared | tail -n 50   # "Registered tunnel connection" 是好的；連線錯誤則否

# 中央是否還收到 remote write，依狀態碼分開
curl -fsS 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=sum by (code) (rate(prometheus_http_requests_total{handler="/api/v1/write"}[5m]))'
# Logs 走同一條 tunnel：Loki 也歸零的話，問題在 tunnel 或 token，不在 Prometheus
curl -fsS 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(loki_distributor_lines_received_total[5m]))'
```

先用 Windows 主機分辨是 tunnel 還是共用 token（Windows 主機走同一條 tunnel，但 token 不同）：

```bash
curl -fsS 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=up{job="integrations/windows"} == 1'
```

- 有結果：tunnel、Access application 與 Prometheus 都正常，問題在 Linux agents 共用的 token `skyeye-agent-push`（到期、撤銷或被移出 policy）。直接看下面第二項。
- 沒有結果：Windows 主機也斷了（或本來就關機），照下面從 cloudflared 開始查。

判讀：

- write rate 是 0、cloudflared 停了或在報錯：重啟 cloudflared。tunnel 已經斷了，所以重啟不會造成額外中斷。
  ```bash
  sudo docker compose restart cloudflared
  ```
- write rate 是 0、cloudflared 看起來正常：到 Cloudflare Zero Trust → Access → Service Auth，檢查 `skyeye-agent-push` 的到期日與狀態；再檢查 `SkyEye Prom push` / `SkyEye Loki push` 兩個 application 的 policy 是否還是 Service Token（見 [`cloudflared/README.md`](../cloudflared/README.md)）。換 token 要更新每台 agent 的 env，需要 Wan 核准，並照各主機的 onboarding 文件處理。
- 有 write 但都是 4xx/5xx：問題在 Prometheus。看 `sudo docker compose logs --since 15m prometheus` 與 `df -h`，磁碟滿就照 [`disk-full.md`](./disk-full.md) 處理。
- 這台主機本身也有問題（Prometheus 停寫、Alertmanager 停了）：外部 dead man's switch 會另外通知，見 [`skyeye-watchdog.md`](./skyeye-watchdog.md)。

## Verify recovery

```promql
count(up{job="integrations/unix"} == 1)   # 回到正常的 agent 數
sum(rate(loki_distributor_lines_received_total[5m])) > 0
```

Agent 在本機有 buffer 並會重試，恢復後幾分鐘內會補送。中斷太久時，部分資料可能遺失。

## Post-incident

- 記下中斷時間與原因（cloudflared、token、Cloudflare），寫進 work-log。
- Token 過期造成的中斷：在密碼管理器記下新的到期日，並排好下次輪替。
- 誤報或漏報要回饋到 shadow review，再決定是否升級。
