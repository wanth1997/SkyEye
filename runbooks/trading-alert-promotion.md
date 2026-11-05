# Trading 告警升級：silence 規則、email 填值、真實 canary

給 operator 在 monitoring-prod 上操作。適用 `TradingCriticalSafetyState`、`TradingProcessDown`、`TradingRiskStopped` 從 `notification_mode=shadow` 升級成 `page` 的過程。

只有這三條可以是 `page`，其他 Trading 告警一律 `shadow`，由 `scripts/trading-target check-alert-modes` 檢查。

| 步驟 | 內容 | 開始前要有 |
|---|---|---|
| B | 填 SMTP 值 | email route 的 PR 已部署，Wan 已提供值 |
| C | 真實 canary | B 完成，Wan 核准 |
| D | 切換 PR | C 通過，Wan 核准 |

下面的指令都在 `/home/ubuntu/SkyEye` 執行：

```bash
cd /home/ubuntu/SkyEye
am() { sudo docker compose exec -T alertmanager "$@"; }
AM=http://127.0.0.1:9093
```

## Silence 規則

**不得單獨 silence `TradingCriticalSafetyState`。** 被 silence 的 source 仍然會抑制 `TradingCriticalLogEvent` 和 `TradingCriticalWarnEvent`，結果三條都送不到。

要靜音就三條一起 silence：

```bash
am amtool silence add --alertmanager.url=$AM --duration=1h \
  --author=operator --comment="REASON" \
  'alertname=~"TradingCriticalSafetyState|TradingCriticalLogEvent|TradingCriticalWarnEvent"' \
  'server_id="SERVER_ID"' 'strategy="STRATEGY"'
```

只 silence Log 或 Warn 沒有這個問題。

## 步驟 B：填 SMTP 值

> **警告：** `email-addresses.tmpl` 語法壞掉時，reload 會被拒，**Alertmanager 重啟也起不來，Telegram 會一起停**。`scripts/central-deploy` 的檢查跑在沒有 secrets 的暫存樹，抓不到這個錯。寫完檔一定要先在 container 內跑 `amtool check-config`，通過才 reload。

這個 repo 是公開的，真實地址不進 Git。`to`、`from` 放 `email-addresses.tmpl`，`smarthost`、`auth_username` 寫在 `alertmanager.yml`，所以 `auth_username` 不能是個人信箱。

1. 確認 email route 的 PR 已經部署。還沒部署就放檔案，舊版 `central-deploy` 會拒絕部署。

   ```bash
   grep -q 'alertmanager/secrets/smtp_password' scripts/central-deploy && echo ready
   ```

2. 放密碼。不要貼在對話裡，也不要用 `echo`。

   ```bash
   read -rs SMTP_PASSWORD
   printf '%s' "$SMTP_PASSWORD" > alertmanager/secrets/smtp_password
   unset SMTP_PASSWORD
   chmod 644 alertmanager/secrets/smtp_password
   ```

3. 放地址。多個收件者用逗號分隔。

   ```bash
   cat > alertmanager/secrets/email-addresses.tmpl <<'EOF'
   {{ define "skyeye.email.to" }}RECIPIENT{{ end }}
   {{ define "skyeye.email.from" }}SENDER{{ end }}
   EOF
   chmod 644 alertmanager/secrets/email-addresses.tmpl
   ```

4. 在 container 內檢查。兩個檔案都要印出 `readable`，`check-config` 要印出 `SUCCESS`。失敗就停下來，刪掉 `email-addresses.tmpl` 重寫，不要 reload。

   ```bash
   am test -r /etc/alertmanager/secrets/smtp_password && echo readable
   am test -r /etc/alertmanager/secrets/email-addresses.tmpl && echo readable
   am amtool check-config /etc/alertmanager/alertmanager.yml
   ```

   輸出的 `1 templates` 只是設定裡的路徑數，不代表檔案存在。這一步抓語法錯誤，抓不到 template 名稱打錯，名稱打錯要到 canary 才看得出來。

5. 檢查通過才 reload。template 要 reload 才生效，密碼檔是寄信時才讀。

   ```bash
   curl -fsS -X POST $AM/-/reload
   curl -fsS $AM/metrics | grep '^alertmanager_config_last_reload_successful'
   ```

   最後一行要是 `1`。

6. 用小 PR 把 `alertmanager.yml` 的 `smarthost`、`auth_username` 換成真實值。只用 port 587 或 465，Alertmanager 只把 465 當直接 TLS。Merge 後跑 `scripts/central-deploy --dry-run`，再跑 `scripts/central-deploy`。

## 步驟 C：真實 canary

需要 Wan 核准。這會真的發一則 Telegram 和一封 email。合成告警不進 Prometheus，所以不影響 dashboard 的告警計數。

1. 確認路由和等待時間。第一行要是 `email-high,telegram-high`，`group_wait` 要是 `0s`。

   ```bash
   am amtool config routes test --config.file=/etc/alertmanager/alertmanager.yml \
     severity=High notification_mode=page
   curl -fsS $AM/api/v2/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["original"])' \
     | grep -A5 'receiver: email-high' | grep group_wait
   ```

2. 記錄失敗次數的基準。

   ```bash
   failed() { curl -fsS $AM/metrics | grep -E '^alertmanager_notifications_failed_total\{integration="(email|telegram)"'; }
   failed > /tmp/canary-failed-before
   ```

3. 送合成告警，記下時間。

   ```bash
   canary() {
     am amtool alert add --alertmanager.url=$AM alertname=SkyEyeCanaryTestOnly severity=High \
       notification_mode=page product=skyeye-canary environment=canary server_id=canary strategy=canary \
       '--annotation=summary="TEST ONLY: SkyEye canary, no action needed"' "$@"
   }
   date -u +%FT%TZ; canary
   ```

4. 確認收到，再等 6 分鐘比對失敗次數。寄送失敗要等重試結束才計入，最長約 5 分鐘。

   ```bash
   sleep 360; failed | diff /tmp/canary-failed-before - && echo unchanged
   ```

5. 結束合成告警。兩邊最晚 5 分鐘內會收到 RESOLVED。

   ```bash
   canary --end="$(date -u +%FT%TZ)"
   ```

**通過標準，四項都要成立：**

| 項目 | 怎麼確認 | 通過 |
|---|---|---|
| Telegram | 看聊天室 | 收到 `SkyEyeCanaryTestOnly` |
| Email | 看信箱 | **信真的收到**。不能只看 metric：SMTP 接受連線但不回應時，`alertmanager_notifications_failed_total` 不會增加 |
| `group_wait` | 第 1 步的設定和兩邊收到的時間 | 設定是 `0s`，送出後幾秒內收到 |
| `alertmanager_notifications_failed_total` | 第 4 步 | 印出 `unchanged` |

沒通過就停在這裡，不要開切換 PR。線上沒有 `page` 告警，Telegram 不受影響。

| 現象 | 先查 |
|---|---|
| 信沒到，failed_total 增加 | `sudo docker compose logs --since 10m alertmanager \| grep -i email`，看認證、DNS、template 名稱 |
| 信沒到，failed_total 沒變 | SMTP 沒有回應，多半是 port 或 TLS 設定錯。修好後 reload |
| 信在垃圾郵件 | 不算通過，先處理寄件者設定 |

## 步驟 D：切換 PR 清單

Canary 通過且 Wan 核准後才開。

- `alertmanager.yml` 已經沒有 `example.invalid`。
- 三條 rule 改 `page`。`TradingCriticalSafetyState` 要先升，或同一個 commit。
- 更新 `prometheus/rules/tests/trading.test.yml` 裡這三條的預期 label。
- 拿掉 email route 的 `notification_mode="page"`，非 Trading 的 High 才開始送 email。
- 把 `test-alert-routing.sh` 的 `High without a mode stays on Telegram` 改成兩個 sink 都收到。
- 更新 `AGENTS.md`、`monitoring-plan-v2.md` 的 email 敘述，以及 `runbooks/trading-process-down.md` 的 shadow 敘述。

## 回滾

| 情況 | 做法 |
|---|---|
| 切換後要退回 | `git revert` 切換 PR，再跑 `scripts/central-deploy` |
| `email-addresses.tmpl` 壞掉，reload 失敗或起不來 | 刪掉這個檔案，再 reload 或重啟。檔案不存在時 Alertmanager 正常運作，只有 email 寄不出去 |
| Email 卡住 | `curl -fsS -X POST $AM/-/reload` 會放掉卡住的 group。SMTP 沒修好，下一封會再卡住，但 Telegram 不受影響 |
| 要停掉 email | 移除 email route，走一般 PR 和 `scripts/central-deploy` |

不要改 `telegram-high` 這個 receiver 的名稱，改名後 reload 會讓 firing 中的告警重送一次 Telegram。
