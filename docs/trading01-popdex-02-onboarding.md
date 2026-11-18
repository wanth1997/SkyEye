# Trading01 新增 `popdex-02` 監控（operator 程序）

> **來源：** tnauqquant manager 的請求卡 WAN-346：Trading01 新增一條 tnauqquant lane `popdex-02`（PopDEX，ETH_USDT_PERP，專用新帳號）。SkyEye task `SKYEYE-POPDEX02-20261119`。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** 它只寫 `popdex-02` 特有的部分：
>
> - 通用的 add／remove 步驟見 [README 的 Add or remove a Trading target](../agents/alloy/trading/README.md#add-or-remove-a-trading-target)。
> - 硬性限制、staging 與 central-deploy 的判讀沿用 [Trading01 PopDEX rollout](trading01-popdex-rollout.md)，下面用「rollout 文件」稱呼它。
> - 這次**不**升級 Alloy、**不**更新共用 probe、**不**動其他 strategy 的 probe。任何一項變成必要時都是 STOP。
>
> **狀態：** 尚未執行。

## Lane 事實與待核對的值

來自 WAN-346、SkyEye 已寫進 `agents/alloy/trading/deployment-linux-popdex-02.env.example` 的事實：

| 項目 | 值 |
|---|---|
| systemd instance | `tnauqquant@popdex-02.service` |
| config | `/home/ubuntu/tnauqquant/config/popdex_02_config.yaml` |
| run-state | `/home/ubuntu/tnauqquant/run-state/popdex-02/` |
| raw log | `/home/ubuntu/tnauqquant/logs/live-runs/<UTC>_popdex_02_config.raw.log` |
| textfile | `tnauqquant-popdex-02.prom` |
| 安裝時的狀態 | `TQ_STRATEGY_DISABLED=1`：lane 安裝後是 disabled，Wan 手動測一個 cycle 之後才 enable |

**SkyEye 不知道、operator 必須在 Trading01 唯讀核對後才填的值。** example 把前兩個留空，`setup-linux.sh` 會拒絕空值，所以 example 原樣無法安裝。不要從 `popdex-btc` 照抄。

| 值 | 怎麼核對 | 填錯的後果 |
|---|---|---|
| `TQ_EXECUTABLE` | `tnauqquant@popdex-02.service` 實際啟動的 binary 絕對路徑（Step 1）。第一次 run 之後再用 manifest 的 `.executable` 確認（Step 5）。 | probe 數不到程序（`process_count 0`），測試 cycle 不會出現 `TradingUnexpectedProcess`，並出現 `TradingRunBindingInvalid` |
| `TQ_EXECUTOR_MAP` | 寫成 `<executor>=popdex`。`<executor>` 是 `popdex_02_config.yaml` 內的 executor 名稱，也是 raw log 的 `executor=` 欄位。新帳號，可能不是 `popdex-main`。 | 沒有告警，但 `exchange="popdex"` 的成交量與持倉 series 不會出現 |
| `TQ_INSTANCE_ID`（example 預填 `popdex-02`，是預期值） | 必須等於 config 的 `instance_id:`（Step 1） | `TradingRunBindingInvalid` |
| 數量欄位名稱 | 共用 probe 讀 raw log 的 `net_qty_btc`／`initiator_qty_btc`／`carrier_qty_btc`，以及 done marker 的 `long_btc`／`short_btc`／`net_btc`／`dust_tolerance_btc`。這條 lane 交易 ETH，欄位名稱是否相同只能在第一次 run 之後確認（Step 5）。 | 持倉 series 不會出現；done marker 不合 schema 時每次 run 結束都會出現 `TradingRunBindingInvalid` |

## 硬性限制

rollout 文件「執行前必讀」的硬性限制全部適用，把其中的 `popdex-btc` 換成 `popdex-02`。這次最容易踩到的：

- **不得 start、stop、restart、enable 或 disable 任何 `tnauqquant@*` service 或 timer，不得修改 tnauqquant 的 config、env、run-state 或程式。** 本文件只讀取它們。lane 的啟動與 enable 由 Wan 決定。
- **順序固定為先 host、後中央。** PR 在時窗開始時才 merge；merge 之後 monitoring-prod 不得執行 `scripts/central-deploy`（包括為了其他變更），直到 Step 3 確認 `popdex-02` 已在 remote-write。
- **時間：** Step 2 到 Step 4 避開 UTC 18:15–19:30；`scripts/central-deploy` 在任何情況下都不得在 UTC 18:30–19:30 執行。
- **Alloy 只 reload。** 不使用 `--restart-alloy`；`add` 要求它就是 STOP。
- **中止規則：** 只要在 Step 3 通過前停下（任何 STOP），下一次 `central-deploy` 之前，manager 先依 README 的 Remove 第 1 步用 `scripts/trading-target remove --server trading01 --strategy popdex-02` 開 PR 並 merge，master 不留沒有 probe 的 row。下次再用 `scripts/trading-target add` 加回。Step 2 已裝上的 probe 可以留著：中央沒有 row 時，`popdex-02` 的 series 不會觸發告警。
- 不加 Alertmanager silence。所有 Trading 告警都是 `notification_mode="shadow"`，不會發 Telegram。
- 不要印出或複製 `popdex_02_config.yaml` 全文與 tnauqquant 的 env 檔，裡面可能有帳號資料。本文件只取指定的單行。

## Step 0 — Staging

照 rollout 文件的 Phase 0 原文執行（`MERGE` 是含本次變更的 master commit 完整 SHA，staging 目錄是 `/home/ubuntu/skyeye-staging/popdex-$M7`）。operator 機器上多確認一項：

```bash
git cat-file -e "$MERGE:agents/alloy/trading/deployment-linux-popdex-02.env.example" && echo MERGE-HAS-POPDEX-02
```

## Step 1 — 唯讀前置檢查（Trading01，root shell）`[READ-ONLY]`

唯一的寫入是 `$WORK` 紀錄目錄。**任何一項不符就 STOP，不進 Step 2**，依中止規則處理。

```bash
sudo -i
MERGE=<完整 SHA>; M7=${MERGE:0:7}
STAGE=/home/ubuntu/skyeye-staging/popdex-$M7
SETUP="$STAGE/agents/alloy/trading/setup-linux.sh"
WORK=/root/skyeye-popdex-02-$(date -u +%Y%m%dT%H%M%SZ); install -d -m 700 "$WORK"
declare -p MERGE M7 STAGE SETUP WORK >"$WORK/vars"

date -u +%H:%M                                           # 不在 18:15–19:30
alloy --version | head -n 1                              # v1.16.3 或 v1.18.1
systemctl is-active alloy                                # active
systemctl show -p CanReload --value alloy                # yes
grep -cxF 'CONFIG_FILE="/etc/alloy"' /etc/default/alloy  # 1
test ! -e /etc/skyeye-trading/instances/popdex-02.env && echo NOT-INSTALLED-YET
cmp "$STAGE/agents/alloy/trading/probe.sh" /usr/local/libexec/skyeye-trading/probe.sh && echo PROBE-SAME
cmp "$STAGE/agents/alloy/trading/ensure-log-access.sh" /usr/local/libexec/skyeye-trading/ensure-log-access.sh && echo ACCESS-SAME
```

- Alloy 版本不在 `agents/alloy/alloy-versions.env` 的 Linux 清單（目前 1.16.3、1.18.1）：STOP，回報版本。不升級，不用 `SKYEYE_ALLOY_UNTESTED_VERSION`。
- `CanReload` 不是 `yes`，或 `CONFIG_FILE` 那一行不是剛好一行：STOP（`add` 會要求 restart）。
- `PROBE-SAME` 或 `ACCESS-SAME` 沒印出：STOP。Trading01 上的共用 probe 檔案比 `MERGE` 舊，`add` 會以 `shared probe artifacts changed while …` 拒絕。更新共用檔案要先停下所有 `skyeye-trading-probe@*`（rollout 文件 Phase 3 的做法），會讓其他 strategy 的 probe 中斷，不在本文件範圍，由 manager 另行安排。`ensure-log-access.sh` 在 2026-11-14 rollout 之後改過，這一項很可能不符。

Lane 路徑與待核對的值：

```bash
ls -ld /home/ubuntu/tnauqquant /home/ubuntu/tnauqquant/config/popdex_02_config.yaml /home/ubuntu/tnauqquant/logs/live-runs
ls -ld /home/ubuntu/tnauqquant/run-state/popdex-02 2>&1 | tee "$WORK/run-state.before"    # 第一次 run 之前可能還不存在，只記錄
grep -nE '^[[:space:]]*instance_id:' /home/ubuntu/tnauqquant/config/popdex_02_config.yaml   # 值必須是 popdex-02
systemctl show -p ExecStart --value tnauqquant@popdex-02.service | tee "$WORK/execstart"
{ systemctl is-active tnauqquant@popdex-02.service; systemctl is-enabled tnauqquant@popdex-02.service; } 2>&1 | tee "$WORK/lane.before"
grep -H '^TQ_EXECUTABLE=' /etc/skyeye-trading/instances/*.env | tee "$WORK/sibling-executables"
```

- 前三個路徑缺任何一個，或 `instance_id` 不是 `popdex-02`：STOP，交給 tnauqquant manager。不要改 example 的 `TQ_INSTANCE_ID` 去配合。
- `TQ_EXECUTABLE`：從 `execstart` 取出 lane 的 binary 絕對路徑。`ExecStart` 是 launcher（例如 `scripts/tq`）而看不出 binary 時，可以唯讀看 unit 與 launcher（`systemctl cat tnauqquant@popdex-02.service`），仍無法確定就 STOP，請 tnauqquant manager 提供。確認 `test -x <路徑>`。
- `<路徑>` 與 `sibling-executables` 裡任何一行相同：STOP。`setup-linux.sh` 要求每個 instance 的 `TQ_EXECUTABLE` 各不相同，共用 binary 的 lane 目前裝不上去，需要 SkyEye 先改 installer。
- `TQ_EXECUTOR_MAP`：在 `popdex_02_config.yaml` 找到這條 lane 的 executor 名稱，只記下名稱。找不到或有多個 executor：STOP，請 tnauqquant manager 提供。
- lane 狀態只記錄，預期 `inactive`／`disabled`。

填好 env 並 render（只寫 `$WORK`）：

```bash
install -m 600 "$STAGE/agents/alloy/trading/deployment-linux-popdex-02.env.example" "$WORK/popdex-02.env"
# 編輯 $WORK/popdex-02.env：只填 TQ_EXECUTABLE=<路徑> 與 TQ_EXECUTOR_MAP=<executor>=popdex，其他不動
diff "$STAGE/agents/alloy/trading/deployment-linux-popdex-02.env.example" "$WORK/popdex-02.env"   # 只有這兩行不同
grep -c '^TQ_STRATEGY_DISABLED=1$' "$WORK/popdex-02.env"                                             # 1
"$SETUP" --render-only "$WORK/render" --env-file "$WORK/popdex-02.env" </dev/null || echo "STOP: render"
grep -c 'strategy *= *"popdex-02"' "$WORK/render/trading-popdex-02.alloy"                            # ≥ 1
```

## Step 2 — Host：加入 `popdex-02` `[CHANGE Trading01]`

```bash
date -u +%H:%M                                           # 不在 18:15–19:30
"$SETUP" add --env-file "$WORK/popdex-02.env" </dev/null 2>&1 | tee "$WORK/add-popdex-02.out"; echo "rc=${PIPESTATUS[0]}"
```

預期（與 rollout 文件 Phase 3 的 `popdex-btc` 相同，只有名稱不同）：

```
Alloy action: reload. Re-evaluates these fragments; unchanged pipelines keep running: …
Validating the combined Alloy configuration before installation
Installed Linux trading monitoring fragment: /etc/alloy/trading-popdex-02.alloy
Rollback record: /etc/skyeye-trading/install-backup/<UTC>-popdex-02-<pid>
Probe metrics: /var/lib/skyeye-trading/textfile/tnauqquant-popdex-02.prom
Alloy reload done; probe timer enabled: skyeye-trading-probe@popdex-02.timer
Next: …
rc=0
```

最後一行 `Next:` 不用理會，inventory row 已在 `MERGE`。

- 輸出有 `--restart-alloy`（`needs a restart`、`Alloy is not active`、`cannot reload the alloy unit`）或 `shared probe artifacts changed`：`add` 在任何變更之前就拒絕了。**STOP 回報，不要加 `--restart-alloy` 重跑。**
- 其他 `rc` 不是 0：`add` 印出 `installation failed; restoring recorded files` 並自行還原。確認 `test ! -e /etc/skyeye-trading/instances/popdex-02.env`，輸出有 `Remaining recovery action: sudo systemctl reload alloy` 時執行那一個 reload，然後 STOP。
- 輸出不能有 `Alloy action: restart`。

檢查：

```bash
systemctl is-active alloy                                # active
systemctl is-enabled skyeye-trading-probe@popdex-02.timer; systemctl is-active skyeye-trading-probe@popdex-02.timer   # enabled / active
sleep 30
grep -E '^tnauqquant_(probe_timestamp_seconds|run_expected|process_count|runtime_contract_available)[{]' \
  /var/lib/skyeye-trading/textfile/tnauqquant-popdex-02.prom | sed 's/[{].*[}]//'
systemctl list-units --all --no-legend --plain 'tnauqquant*' | awk '{print $1, $3, $4}'   # 與安裝前相同，本文件沒有動它們
```

`probe_timestamp_seconds` 在 `date +%s` 的 60 秒內，`run_expected 0`。lane 沒在跑時 `process_count 0`。

## Step 3 — 中央檢查：`popdex-02` 已在 remote-write（monitoring-prod）`[READ-ONLY]`

Step 2 完成後 2 分鐘內，以 `ubuntu` 在 `/home/ubuntu/SkyEye`：

```bash
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
q 'time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",server_id="trading01"}' \
  | jq -c '[.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}] | sort_by(.strategy)'
q 'tnauqquant_run_expected{server_id="trading01",strategy="popdex-02"}' | jq -c '[.[].value[1]]'   # ["0"]
```

- `popdex-02` 那一筆 age < 60，其他 strategy 的筆數與 age 和安裝前一樣：**通過，Step 4 才可以執行。**
- 2 分鐘內 `popdex-02` 沒有出現或 age ≥ 60，其他 strategy 正常：STOP，host 維持現狀，把輸出交給 manager，依中止規則處理。
- 其他 strategy 的 age 也變差（安裝前 < 60，現在不是）：在 Trading01 執行 `"$SETUP" retire --strategy popdex-02 </dev/null`，讓 Alloy 回到安裝前的 fragment 組合，再看一次；然後 STOP，依中止規則處理。

## Step 4 — 中央 inventory：`scripts/central-deploy`（monitoring-prod）`[CHANGE monitoring-prod]`

前提：Step 3 已通過；現在不在 UTC 18:30–19:30；monitoring-prod 上沒有其他 operator。沿用 Step 3 的 shell（`q` 已定義）。

```bash
cd /home/ubuntu/SkyEye
MERGE=<完整 SHA>
date -u +%H:%M
scripts/central-deploy --dry-run --expect "$MERGE"
scripts/central-deploy --expect "$MERGE"; echo "rc=$?"
sleep 70
q 'trading_target_info{strategy="popdex-02"}' | jq -c '[.[].metric | {server_id, strategy, notification_mode}]'
q 'trading_target_info unless on (product, environment, server_id, strategy) (time() - trading_strategy_probe_timestamp_seconds < 180)'   # []
q 'ALERTS{product="tnauqquant",server_id="trading01",alertstate="firing"}' | jq -c '[.[].metric | {alertname, strategy}] | sort'
```

- dry run 的最後一行必須是 `Dry run: validation passed; …`，部署的最後一行必須是 `central-deploy: done; applied <12 碼 SHA>`。拒絕或失敗時的判讀與 rollback 依 rollout 文件的 Phase 5 與 R5（把 `popdex-btc` 換成 `popdex-02`），不要改用 `git pull` 或 `git reset --hard`。
- `trading_target_info` 預期一筆 `trading01`／`popdex-02`／`shadow`；`unless` 查詢預期 `[]`。
- lane 停著且 disabled 時，`popdex-02` 預期沒有任何 firing 告警。

## Step 5 — Wan 手動測試 cycle 之後的唯讀核對 `[READ-ONLY]`

Wan 跑完手動測試 cycle 之後、lane 正式 enable 之前，在 Trading01 確認留空與預期的值：

```bash
jq -r '.executable, .instance_id, .strategy' /home/ubuntu/tnauqquant/run-state/popdex-02/current.json
grep -E '^TQ_(EXECUTABLE|INSTANCE_ID|STRATEGY|EXECUTOR_MAP)=' /etc/skyeye-trading/instances/popdex-02.env
LOG=$(ls -1t /home/ubuntu/tnauqquant/logs/live-runs/*popdex_02_config.raw.log | head -n 1)
grep -oE '(^|[[:space:]])executor=[^[:space:]]+' "$LOG" | sort | uniq -c
grep -oE '(net|initiator|carrier)_qty_[a-z0-9]+=' "$LOG" | sort | uniq -c
jq -r 'keys[]' /home/ubuntu/tnauqquant/run-state/popdex-02/current.done.json 2>/dev/null | grep -E '^(long|short|net|dust_tolerance)_'
grep -E '^tnauqquant_(process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok|current_run_exchange_volume_usd|current_position_btc)[{]' \
  /var/lib/skyeye-trading/textfile/tnauqquant-popdex-02.prom
```

- manifest 的 `.executable`、`.instance_id`、`.strategy` 必須分別等於 env 的 `TQ_EXECUTABLE`、`TQ_INSTANCE_ID`、`TQ_STRATEGY`；raw log 的 executor 必須是 `TQ_EXECUTOR_MAP` 等號左邊的名稱。`TQ_EXECUTABLE` 或 `TQ_EXECUTOR_MAP` 不符：改 `$WORK/popdex-02.env` 後照 Step 2 的 `add` 重跑一次（就地更新，Alloy 只 reload）。`instance_id` 或 `strategy` 不符：STOP，交給 tnauqquant manager。
- 數量欄位不是 `*_qty_btc`，或 done marker 沒有 `long_btc`／`short_btc`／`net_btc`／`dust_tolerance_btc`：共用 probe 讀不到這條 lane 的持倉，done marker 也會被判為 binding 不成立。**不要改 probe，回報 manager**；這需要 SkyEye 另開變更，lane enable 之前要先決定。
- 五個 `…_ok`／`config_snapshot_match` 都是 `1` 才算核對完成。

## 正式 enable 之前：把 `TQ_STRATEGY_DISABLED` 改回 `0` `[CHANGE Trading01]`

Wan 決定 enable lane 時，在 lane 啟動**之前**執行（不在 UTC 18:15–19:30）：

```bash
install -m 600 /etc/skyeye-trading/instances/popdex-02.env "$WORK/popdex-02.enable.env"
sed -i 's/^TQ_STRATEGY_DISABLED=1$/TQ_STRATEGY_DISABLED=0/' "$WORK/popdex-02.enable.env"
diff /etc/skyeye-trading/instances/popdex-02.env "$WORK/popdex-02.enable.env"    # 只有 TQ_STRATEGY_DISABLED 那一行
"$SETUP" add --env-file "$WORK/popdex-02.enable.env" </dev/null 2>&1 | tee "$WORK/add-popdex-02.enable.out"; echo "rc=${PIPESTATUS[0]}"
```

預期 `Alloy action: reload…`、`Updating installed instance in place; pausing its probe timer: skyeye-trading-probe@popdex-02.timer`、`Alloy reload done; probe timer enabled: …`、`rc=0`。失敗時 `add` 自行還原 env 與 timer 狀態，lane 維持 disabled 的監控語意，STOP 回報。這一步只改 SkyEye 的 probe env，lane 本身仍由 Wan 啟動。

## 預期的 shadow 告警（不是失敗）

全部是 `notification_mode="shadow"`，只會出現在 Grafana 與 Alertmanager，不發通知。

`TQ_STRATEGY_DISABLED=1` 期間（probe 回報 `run_expected=0`）：

| 情況 | `popdex-02` 的告警 |
|---|---|
| lane 停著 | 沒有 |
| Wan 的手動測試 cycle 跑超過 2 分鐘 | `TradingUnexpectedProcess`，程序結束後消失。這就是 disabled 的 lane 被啟動時應有的訊號 |
| 測試 cycle 以 `risk_halt`、`max_cycles_drain_failed` 或無法辨識的 reason 結束 | `TradingCriticalSafetyState`（此時不再顯示 `TradingUnexpectedProcess`）；`pnl_status` 回報 `risk_stopped=true` 時另有 `TradingRiskStopped`。這是 lane 的真實狀態，交給 Wan |
| manifest 存在但 binding 不成立 | `TradingRunBindingInvalid`（不看 `run_expected`）。原因可能是 `TQ_EXECUTABLE`／`TQ_INSTANCE_ID` 填錯、config 在 run 開始後被改，或 done marker 的欄位不合 schema。依 Step 5 核對 |
| 中央比 host 先部署，或 probe 停超過 180 秒 | `TradingTelemetryMissing` |

disabled 期間**不會**出現 `TradingProcessDown`、`TradingRuntimeContractMissing`、`TradingPnlTelemetryStale`，它們都要求 `run_expected=1`。測試 cycle 沒有留下 done marker 就停下時，留下的 `running` manifest 也不會被當成 ProcessDown。

改回 `TQ_STRATEGY_DISABLED=0` 之後、lane 啟動之前：沒有 manifest 時出現 `TradingProcessDown` 與 `TradingRuntimeContractMissing`；測試 cycle 留下 `running` manifest 時出現 `TradingProcessDown`。lane 啟動後消失；剛啟動、第一筆 `pnl_status` 寫出之前可能短暫出現 `TradingPnlTelemetryStale`。

Step 2 到 Step 4 的 UTC 時窗，以及 Wan 的手動測試 cycle，都寫進執行紀錄，並從 `trading01`／`popdex-02` 的 shadow 證據中排除。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Step 0 staging | | `MERGE`、`STAGE` |
| Step 1 前置檢查 | | `WORK`、Alloy 版本、填入的 `TQ_EXECUTABLE` 與 executor 名稱及其來源 |
| Step 2 host add | | `Rollback record:` 路徑、`rc` |
| Step 3 中央檢查 | | `popdex-02` 的 age |
| Step 4 central-deploy | | applied SHA |
| Step 5 測試 cycle 後核對 | | 五個 binding 值、數量欄位名稱 |
| `TQ_STRATEGY_DISABLED=0` | | `Rollback record:` 路徑 |
