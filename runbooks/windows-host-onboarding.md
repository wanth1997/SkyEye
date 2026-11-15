# Windows 主機上線與告警處理

把一台 Windows 主機接上 SkyEye：主機指標、Alloy 自身的推送狀態、System / Application Event Log，之後可加上 GitHub Actions runner 的 listener log。第一台是 `wans-windows`（`product="github-runner"`）。Dashboard 是 Grafana 的 **主機 — Windows**（uid `hosts-windows`）。

安裝器的每一步、STOP 點與 rollback 條件寫在 [`agents/alloy/windows/README.md`](../agents/alloy/windows/README.md)。這份只講操作順序。

**分工：** 主機上的 agent 沒有管理員權限，只能跑 Check 和讀結果檔。需要提升權限的三件事（放 token、Install、Rollback / Uninstall）由 Wan 在 UAC 視窗親自執行。安裝器不會提示輸入，也沒有任何參數接受憑證。

## 1. 前置

**Alloy 版本。** 安裝器不會安裝 Alloy，只接受 `agents/alloy/alloy-versions.env` 裡 `SKYEYE_ALLOY_WINDOWS_VERSIONS` 列出的版本（目前 1.18.1），其他版本一律拒絕。主機上沒有 Alloy 時，由 Wan 在提升權限的 PowerShell 執行：

```powershell
winget install --id GrafanaLabs.Alloy --version 1.18.1 --exact --silent --accept-package-agreements --accept-source-agreements
winget pin add --id GrafanaLabs.Alloy --version 1.18.1   # winget upgrade --all 不會動到它
```

**Access token。** 每台 Windows 主機用自己專屬的 Cloudflare Access service token，不共用 Linux agents 的 `skyeye-agent-push`。兩個檔案放在 `C:\ProgramData\SkyEye\secrets\`，只有 SYSTEM 與 Administrators 能讀，內容不能有 BOM 或結尾換行。由 Wan 在提升權限的 PowerShell 執行（secret 不回顯、不進 history、不經過命令列）：

```powershell
$dir = 'C:\ProgramData\SkyEye\secrets'
New-Item -ItemType Directory -Force $dir | Out-Null
icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$dir\cf-access-client-id", (Read-Host 'Client ID').Trim(), $utf8)
$s = Read-Host 'Client Secret' -AsSecureString
$p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
try { [IO.File]::WriteAllText("$dir\cf-access-client-secret", [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p).Trim(), $utf8) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p); Remove-Variable s, p }
icacls $dir /setowner '*S-1-5-32-544' /T | Out-Null
```

安裝器只看這兩個檔的存在、大小與 ACL，不會打開它們，也不會修 ACL。ACL 不對時它會停下來並列出多出來的帳號；用上面的 `icacls` 兩行修正。

**檔案。** 把 repo 的整個 `agents/alloy/` 目錄帶到主機（`git clone` 或複製），例如 `C:\SkyEye\agents\alloy\`。只複製 `windows\` 子目錄會缺版本清單。

## 2. Check（不需管理員，不改任何東西）

```powershell
cd C:\SkyEye
powershell.exe -NoProfile -ExecutionPolicy Bypass -File agents\alloy\windows\install.ps1 -Product github-runner -ServerId wans-windows
Get-Content C:\ProgramData\SkyEye\reports\windows-agent-install-latest-user.json
```

預期 `status: checked`、exit 0。非管理員讀不到 secret 檔與現行 config，所以 `secret_files`、`secret_acl`、`live_config`、`label_takeover`、`smoke_run` 會是 **`skipped`，不是 `passed`**；這些檢查在下一步提升權限後才真的執行。`alloy_version`、`alloy_service_account`、`alloy_validate` 任何一項 `failed` 就先解決，不要進下一步。

## 3. Install（Wan，提升權限）

```powershell
Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\SkyEye\agents\alloy\windows\install.ps1','-Product','github-runner','-ServerId','wans-windows','-Mode','Install'
Get-Content C:\ProgramData\SkyEye\reports\windows-agent-install-latest-admin.json
```

提升權限的視窗結束就關閉，結果只在結果檔裡。每次執行另有 `windows-agent-install-<run id>.json` 與 `.log`。

| `status` | exit | 意思 |
|---|---|---|
| `installed` / `already_current` | 0 | 新 config 上線且通過 health gate；或 config 本來就一樣且健康 |
| `checked` / `restored_previous` | 0 | Check 模式跑完（沒有改任何東西）；`-Mode Rollback` 換回上一份 config 且通過 health gate |
| `refused` / `failed_validate` / `failed_smoke` | 1 | 換 config 之前就停了，主機沒有任何改變。`stop_point` 與 `message` 說明原因 |
| `rolled_back` | 1 | 換了之後 health gate 沒過，已換回舊 config 並確認服務正常 |
| `unhealthy_no_change` | 1 | config 沒變，但目前的服務不健康 |
| `rollback_incomplete` | 3 | 換回舊 config 沒有完成。照 `message` 的指示手動處理，並回報 |

Install 會先用獨立的 port 與暫存目錄真的跑一次 render 出來的 config（push URL 指向關閉的本機 port），不碰現行服務的 `127.0.0.1:12345`、data 目錄與 Event Log bookmark。這一步能抓到 `alloy validate` 抓不到的「secret 不能轉成字串」錯誤。換上去之後，health gate 要求 120 秒內 Prometheus 確實收下一批資料（看 `queue_highest_sent_timestamp_seconds`，不是只會算嘗試次數的 `samples_total`）、沒有失敗的 sample，並且 Loki 收下至少一筆 log。

**Canary。** 這台主機的 token 從沒推過 log，安靜的桌機也可能好幾分鐘沒有 Warning 以上的事件，所以安裝器會寫一筆 Warning 到 Application log：來源 `SkyEye`、Event ID `4242`，內文固定為

```
SkyEye installer canary: Windows Event Log to Loki delivery check. Safe to ignore.
```

`SkyEye` 這個 event source 在第一次 Install 時註冊，之後一直留著（解除安裝也不移除）。

**標籤衝突。** 現行 config 已經有 `product` / `server_id`，而且跟這次的參數不同時，安裝器會拒絕（`label_takeover`）：已經在中央的 series 不能因為接手而換標籤。

## 4. 中央端驗證

```promql
up{job="integrations/windows", server_id="wans-windows"}                          # 1
windows_os_info{server_id="wans-windows"}                                        # product="github-runner"，os_product="Windows 11 …"
time() - prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job="integrations/self", server_id="wans-windows"}   # 幾十秒內
```

```logql
{job="windows-eventlog", server_id="wans-windows"} |= "SkyEye installer canary"
```

- **第一次啟動沒有 bookmark，Alloy 只收之後的新事件，不回補歷史。** 所以剛裝好時 Loki 裡只有 canary；看不到其他 log 不代表壞了。
- **`windows_os_info` 是唯一刻意改標籤的 series。** 它自帶的 `product`（例如 `Windows 11 Home`）原本會蓋掉 SkyEye 的產品標籤；現在 `product="github-runner"`，舊值移到 `os_product`。接手前的那條舊 series 會自然過期。其他 series 的 `job`、`instance`、`product`、`server_id` 都不變。
- 接手後不再送的指標：每核心的 C-state / 頻率 / 中斷明細，以及標籤帶有磁碟序號、執行檔路徑、服務帳號、IP、MAC 的 info 指標。完整清單在 `tests/fixtures/windows/windows-exporter-v0.31.3-metrics.txt`（標 `drop` 的 18 個）。

## 5. Rollback 與解除安裝（Wan，提升權限）

```powershell
# 回到上一份 config（config.alloy.previous），同樣有 validate 與 health gate
Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\SkyEye\agents\alloy\windows\install.ps1','-Mode','Rollback'

# 讓這台主機離開 SkyEye：停用服務，留下一份沒有 pipeline 的 config
Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\SkyEye\agents\alloy\windows\uninstall.ps1'
```

- 解除安裝預設保留 secret 檔（刪了只有 Wan 能補回）；確定要刪才加 `-RemoveSecrets`。原本的 config 留在旁邊的 `config.alloy.uninstalled-<run id>`。
- 留下不動的東西：Alloy 套件（`winget uninstall --id GrafanaLabs.Alloy`）、它的 data 目錄、`SkyEye` event source（`[System.Diagnostics.EventLog]::DeleteEventSource('SkyEye')`）、已經送到中央的資料。
- 主機停止回報 1 小時後 `WindowsHostStale` 會觸發（shadow，不通知），最後一筆資料滿 7 天後自動消失，不需要清理。
- **`config.alloy.rollback` 存在** 代表上一次執行中途被砍掉，檔案內容是那次執行之前的 config。安裝器會拒絕再跑（`unfinished_run`）。比對它跟 `config.alloy`，把它搬回去或刪掉，再重跑 Check。

## 6. 之後加上 runner

Runner 以 Windows 服務安裝後（服務名 `actions.runner.<owner>-<repo>.<runner>`），服務狀態指標會自動出現，不必重裝。Repo 名稱會成為 `name` 標籤的值，這點已接受。要收 runner 的 listener log，重跑第 2、3 步並加上 `-RunnerDiagDir`：

```powershell
... install.ps1 -Product github-runner -ServerId wans-windows -RunnerDiagDir 'C:\actions-runner\_diag'
```

只收 `Runner_*.log`（去識別化後送出），不收 `Worker_*.log`：後者含整份 job 內容，而 job log 本來就在 GitHub 上。

目前沒有 runner 服務的告警，因為還沒有 series 可以做 shadow 觀察。Runner 上線後，在 `prometheus/rules/windows.yml` 加上下面這條，並在同一個 PR 補 `prometheus/rules/tests/windows.test.yml` 的案例：

```yaml
- alert: WindowsRunnerServiceDown
  expr: windows_service_state{name=~"actions\\.runner\\..+", state="running"} == 0
  for: 15m
  labels: {severity: Medium, notification_mode: shadow}
```

## 7. 告警處理

五條都在 `prometheus/rules/windows.yml`，全部是 `notification_mode: shadow`：不送 Telegram，只出現在 Prometheus 與 dashboard 的告警表。

| 告警 | 條件 | 先看什麼 |
|---|---|---|
| `WindowsHostStale` (Medium) | 7 天內回報過，但已 1 小時沒有健康的 `up` | 主機是否開機、Alloy 服務是否 Running；token 是否到期或被撤銷；跑一次 Check 看結果檔。其他主機也同時沒資料就改看 [`all-remote-agents-silent.md`](./all-remote-agents-silent.md) |
| `WindowsDiskLow` (Medium) / `WindowsDiskCritical` (High) | 磁碟機剩餘 < 10% 達 30 分鐘 / < 5% 達 15 分鐘 | Dashboard「磁碟」列看是哪一槽與成長速度；runner 的 `_work`、Docker / 套件快取、Windows Update 殘留 |
| `WindowsClockSkew` (Medium) | 與時間來源相差 > 5 秒達 30 分鐘 | `w32tm /query /status`、`w32tm /resync`；時鐘偏移會讓 TLS 與 token 驗證失敗 |
| `AlloyAgentPushFailing` (Medium) | metrics 推送有失敗的 sample，或 log 被丟棄，持續 15 分鐘 | 下面的查詢分辨是哪一條路 |

```promql
sum by (url) (rate(prometheus_remote_storage_samples_failed_total{job="integrations/self", server_id="wans-windows"}[10m]))
sum by (reason) (rate(loki_write_dropped_entries_total{job="integrations/self", server_id="wans-windows"}[10m]))
```

只有 log 被丟而 metrics 正常：通常是 Loki 那個 Access application 沒有納入這台主機的 token，或 Loki 拒收（看 `reason`）。兩邊都失敗時告警本身也送不出來，會由 `WindowsHostStale` 接手。主機端的細節在 Application log 裡來源為 `Alloy` 的事件。

**升級出 shadow：** 依 AGENTS.md，要先有 shadow 觀察與一次真實 canary。改 `notification_mode` 的同一個 commit 必須一起改 `tests/windows/test-windows-central.sh`（它要求 Windows 告警都在 shadow）與 rule test。Email 路由的啟用見 [`trading-alert-promotion.md`](./trading-alert-promotion.md)。
