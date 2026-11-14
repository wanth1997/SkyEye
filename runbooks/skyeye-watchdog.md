# `SkyEyeWatchdog` — 外部 dead man's switch

這條告警永遠在 firing，Alertmanager 會把它當成 ping 送到外部 heartbeat 服務。monitoring-prod 自己掛掉時，就是外部服務沒再收到 ping 而通知 Wan。告警不是從中央發出的，這裡沒有 Telegram 訊息可以點。

## 運作方式

- Rule：`prometheus/rules/deadman.yml`，`time() - (prometheus_tsdb_head_max_time / 1000) < 120`，綁在 TSDB head 上，不用 `vector(1)`。head 停止前進後約 2 分鐘內停止 firing；self-scrape 完全寫不進去時，series 在 5 分鐘內 stale。
- Route：`alertmanager/alertmanager.yml` 第一條 route，`group_wait 0s`、`group_interval 1m`、`repeat_interval 5m`，每 5～6 分鐘 ping 一次。不走 shadow，外部服務就是它的 canary。
- Receiver `deadman-external`：一般 webhook，對 `alertmanager/secrets/deadman_url` 裡的網址送 JSON POST，`send_resolved: false`。網址本身就是 credential，不進 Git。每次發送時才讀檔，換檔不需要 reload。
- 外部 check：period 5 分、grace 10 分。最後一次 ping 之後約 15～16 分鐘告警。

| 抓得到 | 抓不到 |
|---|---|
| EC2、Docker、Prometheus、Alertmanager 掛掉；磁碟滿導致 TSDB 停寫；出站網路中斷 | Tunnel 入站中斷（見 [`all-remote-agents-silent.md`](./all-remote-agents-silent.md) 與下方 tunnel 探測）；Loki、Grafana 掛掉（`LokiDown`、`GrafanaDown`） |

## 部署後、放 secret 前的狀態

這是部署後的正常狀態，可以維持任意久：

- `amtool check-config` 通過，Alertmanager 正常 reload 與啟動，不會 crash loop。
- `SkyEyeWatchdog` 在 Prometheus 裡 firing，Overview 看不到它（`severity="None"`）。
- 每分鐘一行 Alertmanager error log：`deadman-external/webhook[0]: notify retry canceled due to unrecoverable error after 1 attempts: read url_file: open /etc/alertmanager/secrets/deadman_url: no such file or directory`。不重試，沒有任何流量離開主機。
- `alertmanager_notifications_failed_total{integration="webhook"}` 每分鐘 +1。`AlertmanagerNotifyFailures` 不看 webhook，所以不會送 Telegram。
- 其他 route 與 Telegram 完全不受影響。

`tests/stack/test-deadman-switch.sh` 會用真的 Alertmanager 驗證這個狀態，以及放入 secret 之後的行為。

## 一次性設定（依序）

### 1. 部署

任何時間都可以做，只有熱 reload。

```bash
cd /home/ubuntu/SkyEye
scripts/central-deploy --dry-run
scripts/central-deploy --expect <reviewed-sha>
```

檢查：

```bash
curl -fsS 'http://127.0.0.1:9090/api/v1/rules?type=alert' | grep -o '"state":"firing","name":"SkyEyeWatchdog"'
sudo docker compose logs --since 3m alertmanager | grep -c 'read url_file'   # 預期 >= 1，secret 還沒放
```

central-deploy 先 reload Prometheus，再 reload Alertmanager。如果 Alertmanager 拒絕 reload，舊設定沒有這條 route，Watchdog 會掉到 root receiver（`telegram-medium`），所以要立刻照 central-deploy 印出的 rollback 指令做（`git reset --hard … && curl -X POST …/-/reload`），把 rule 拿掉。`amtool check-config` 已先驗過，這個情況不應該發生。

### 2. 建立託管 check

由 Wan 在託管服務上建立，例如 Healthchecks.io 或 Better Stack heartbeat。只要服務接受「對秘密網址的 POST，回 2xx 就算一次 ping」即可。

- 名稱：`skyeye-monitoring-prod`
- Schedule：Simple，**period 5 分鐘、grace 10 分鐘**
- 通知：**第一週只寄 email 給 Wan**。連續 7 天沒有誤報後，再加上服務**自己的** Telegram integration。不要用 SkyEye 的 `tg_token`，通知路徑不能經過 monitoring-prod。
- Ping URL 存進密碼管理器。不要貼進對話、ticket 或 commit。

### 3. 放 secret

一定要在第 1 步之後。舊版 `scripts/central-deploy` 不認得這個檔案，會拒絕部署。

權限與 `tg_token` 相同：owner `ubuntu`、mode `0644`，目錄 `0755`。Alertmanager container 以 `nobody`（uid 65534）執行，讀不到 `0600`，原因見 [`alertmanager/secrets/README.md`](../alertmanager/secrets/README.md)。

```bash
cd /home/ubuntu/SkyEye/alertmanager/secrets
read -rs DEADMAN_URL          # 貼上 ping URL，按 Enter，畫面不顯示
printf '%s\n' "$DEADMAN_URL" > deadman_url.tmp
unset DEADMAN_URL
chmod 644 deadman_url.tmp
mv deadman_url.tmp deadman_url   # rename：container 只會看到完整的檔案

# 只看長度與開頭，不印內容
wc -c < deadman_url
grep -c '^https://' deadman_url   # 預期 1
```

不需要 reload。

### 4. 確認 ping 有到

2 分鐘內：

- 託管 check 顯示收到 ping，狀態 up。
- `sudo docker compose logs --since 2m alertmanager | grep -c 'read url_file'` 是 `0`。
- `curl -fsS http://127.0.0.1:9093/metrics | grep 'notifications_failed_total{integration="webhook"'` 的數字不再增加。

收到 4xx（`reason="clientError"`）代表網址錯了，回第 3 步重放。

### 5. 一次性 20 分鐘 Alertmanager 停止測試

確認外部服務真的會叫。只做一次。託管 check 要先綠燈至少一天。

- **時段：** 避開 18:50～19:30 UTC，也就是備份與 Trading 時段。
- **前提：** 沒有 firing 的 High 或 Trading 告警。事先告知 Wan。停止期間所有告警都不會送出。

```bash
cd /home/ubuntu/SkyEye
date -u
sudo docker compose stop alertmanager
```

- 預期停止後 9～16 分鐘，Wan 收到託管服務的「down」email。最多等 **20 分鐘**。
- 不論有沒有收到，20 分鐘一到就恢復，不要延長停機：

```bash
sudo docker compose start alertmanager
curl -fsS http://127.0.0.1:9093/-/ready
```

- 預期約 2 分鐘內收到「up」email。停止期間 firing 的告警，會在 Prometheus 重送後補發。
- 20 分鐘內沒收到 down email，代表測試失敗：檢查託管服務的通知設定，修好後另約時段重測。
- 把結果（時間、down 與 up email 的時間）記在 work-log。

### 6. Tunnel 探測：後續工作

專用 hostname（cloudflared 直接回 204）加外部 HTTP 監控，用來抓 tunnel connector 中斷。這需要一次 cloudflared recreate，要在低流量時段做，且絕不在 18:15～19:30 UTC。它不在這次變更裡，另開任務處理。在那之前，tunnel 中斷只有 [`AllRemoteAgentsSilent`](./all-remote-agents-silent.md)（shadow）與 `LokiIngestStalled` 會反映。

## 外部服務告警時

外部服務說沒收到 ping，代表下列其中一件事發生了：monitoring-prod 停了、Prometheus 不再寫入、Alertmanager 停了，或者出站網路斷了。

```bash
# 先 SSH 到 monitoring-prod。連不上：到 AWS console 看 EC2 status check，必要時 reboot
cd /home/ubuntu/SkyEye
sudo docker compose ps                                   # 每個 service 都要 Up
df -h / /var/lib/docker                                  # 磁碟滿會讓 TSDB 停寫
curl -fsS http://127.0.0.1:9090/-/ready; curl -fsS http://127.0.0.1:9093/-/ready
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=time()-prometheus_tsdb_head_max_time/1000'
sudo docker compose logs --since 30m prometheus alertmanager | tail -n 100
sudo docker compose logs --since 30m alertmanager | grep deadman-external | tail -n 5
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com   # 出站網路
```

- Container 停了：`sudo docker compose up -d <service>`。
- 磁碟滿：照 [`disk-full.md`](./disk-full.md) 處理這台主機。
- 主機都正常、ping 卻失敗：看 `deadman-external` 的錯誤。4xx 通常是網址被輪替或 check 被刪了。託管服務本身故障的話，到它的 status page 確認。
- 恢復後幾分鐘內，託管服務會送「up」。

## 計畫內停機

重開機、restore、停 Prometheus 或 Alertmanager 超過 10 分鐘之前，先在託管服務上 pause 這個 check，結束後再 resume，否則會誤報。

## Secret 輪替與停用

- 輪替：在託管服務重新產生 ping URL，照第 3 步重放，不需要 reload。
- 停用：revert 這次 commit 並用 `scripts/central-deploy` 部署，刪掉 `alertmanager/secrets/deadman_url`，再刪掉託管 check。
