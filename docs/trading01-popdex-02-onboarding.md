# Trading01 新增 `popdex-02` 監控（operator 程序）

> **來源：** tnauqquant manager 的請求卡 WAN-346：Trading01 新增一條 tnauqquant lane `popdex-02`（PopDEX，ETH_USDT_PERP，專用新帳號）。SkyEye task `SKYEYE-POPDEX02-20261119`。
>
> **本文件是 operator 程序，repo 變更 merge 後不會自動生效。** 它只寫 `popdex-02` 特有的部分：
>
> - 通用的 add／remove 步驟見 [README 的 Add or remove a Trading target](../agents/alloy/trading/README.md#add-or-remove-a-trading-target)。
> - 硬性限制、staging、central-deploy 的判讀與 R5 沿用 [Trading01 PopDEX rollout](trading01-popdex-rollout.md)，下面用「rollout 文件」稱呼它。
> - 這次**不**升級 Alloy、**不**更新共用 probe、**不**動其他 strategy 的 probe。任何一項變成必要時都是 STOP。
>
> **狀態：** SkyEye 這一側尚未執行。lane 那一側已安裝（見下方 producer 回報）。

## Lane 事實與待核對的值

來自 WAN-346、SkyEye 已寫進 `agents/alloy/trading/deployment-linux-popdex-02.env.example` 的事實：

| 項目 | 值 |
|---|---|
| systemd instance | `tnauqquant@popdex-02.service` |
| config | `/home/ubuntu/tnauqquant/config/popdex_02_config.yaml` |
| run-state | `/home/ubuntu/tnauqquant/run-state/popdex-02/` |
| raw log | `/home/ubuntu/tnauqquant/logs/live-runs/<YYYYMMDD_HHMMSS>_popdex_02_config.raw.log`。`TQ_RAW_LOG_GLOB` 只選這個形式，同目錄裡名稱相似的檔案不算這條 lane |
| textfile | `tnauqquant-popdex-02.prom` |
| 安裝時的狀態 | `TQ_STRATEGY_DISABLED=1`：lane 安裝後是 disabled，Wan 手動測一個 cycle 之後才 enable |

**producer 回報。** lane 那一側的安裝（WAN-345）完成後，tnauqquant manager 回報了 Trading01 上的狀況。這是 producer 提供的資料，不是 Wan 的核准，SkyEye 也沒有在主機上核對過；Step 1 與 Step 5 仍照下面的方式唯讀核對。

| 項目 | producer 回報 |
|---|---|
| lane 的狀態 | 已安裝。`tnauqquant@popdex-02` 的 service 與 timer 都是 disabled、inactive，尚未啟動。Wan 填好 lane 的憑證與 ETH model 之後，會手動 start 一個 cycle（`max_cycles=1`） |
| 啟動方式 | 所有 lane 共用 template `tnauqquant@.service`，`ExecStart=/usr/local/sbin/tnauqquant-service launch %i`。這是共用的 launcher，不是 quant binary |
| quant binary | `/home/ubuntu/tnauqquant/bin/popdex-02/quant`，記在這條 lane 設定檔的 `TNAUQ_EXPECTED_BIN`。形式與 `popdex-btc` 的 `/home/ubuntu/tnauqquant/bin/popdex-btc/quant` 相同 |
| executor | config 的 `routing.accounts[0].name` 是 `popdex-main`，exchange 是 `popdex_usdt_perp`。名稱與 `popdex-btc` 相同（config 照抄） |
| 數量 | config 是 `execution.quantity`（`quantity_unit: base`），這條 lane 的 base 是 ETH。raw log 的欄位名稱沒有改，仍是 `*_btc`（`requested_btc`、`quantity_btc`、`net_qty_btc` 等），值是 ETH 數量 |

**operator 必須在 Trading01 唯讀核對後才填的值。** example 把前兩個留空，`setup-linux.sh` 會拒絕空值，所以 example 原樣無法安裝。`TQ_EXECUTABLE` 每條 lane 不同，不要從 `popdex-btc` 照抄。

| 值 | 怎麼核對 | 填錯的後果 |
|---|---|---|
| `TQ_EXECUTABLE` | 這條 lane 的 quant binary 絕對路徑，**不是** `ExecStart` 的 launcher。producer 回報 `/home/ubuntu/tnauqquant/bin/popdex-02/quant`；Step 1 只取 lane 設定檔 `/etc/tnauqquant/instances/popdex-02/manager.env` 的 `TNAUQ_EXPECTED_BIN` 那一行核對。第一次 run 之後用 manifest 的 `.executable` 確認（Step 5）。 | 填成 launcher：它每條 lane 都相同，另一個 instance 也這樣填時 `setup-linux.sh` 的不重複檢查會拒絕；裝得上去 probe 也數不到程序（`process_count 0`），測試 cycle 不會出現 `TradingUnexpectedProcess`，並出現 `TradingRunBindingInvalid` |
| `TQ_EXECUTOR_MAP` | 寫成 `<executor>=popdex`。`<executor>` 是 config 的 `routing.accounts[0].name`，也是 raw log 的 `executor=` 欄位。producer 回報 `popdex-main`，所以是 `popdex-main=popdex`。名稱與 `popdex-btc` 相同並不衝突：executor map 是每個 instance 自己的，probe 只讀自己這條 lane 的 raw log，跨 lane 用 `strategy`／instance 區分。Step 1 在 config 核對，Step 5 用 raw log 核對。 | 沒有告警，series 也照樣出現：`exchange="popdex"` 的成交量會是 `0`（漏計），單一 executor 的淨持倉仍掛在 `popdex` 上。**series 存在不代表映射正確**，要用 Step 5 同一個已成交 cycle 的 executor 名稱與成交額核對 |
| `TQ_INSTANCE_ID`（example 預填 `popdex-02`，是預期值） | 等於 config 的 `instance_id:`，且與 Trading01 其他 instance 不同（Step 1）。config 是別的值時填 config 的值。第一次 run 之後用 manifest 的 `.instance_id` 確認（Step 5）。 | `strategy_identity_ok 0`；manifest 存在時出現 `TradingRunBindingInvalid` |
| 數量欄位的名稱與單位 | 共用 probe 讀 raw log 的 `net_qty_btc`／`initiator_qty_btc`／`carrier_qty_btc`，以及 done marker 的 `long_btc`／`short_btc`／`net_btc`／`dust_tolerance_btc`，原值輸出成 `tnauqquant_current_position_btc`，沒有換算。Trading01 的共用 probe 還是本文件 `MERGE` 那一版時，Grafana 固定標成 BTC；改標 ETH 要另依 [README 的 Position units](../agents/alloy/trading/README.md#position-units-tq_base_asset) 上線（`TQ_BASE_ASSET=ETH`，需要更新共用 probe，不在本文件範圍）。producer 已確認欄位名稱仍是 `*_btc`、值是 ETH 數量。第一次 run 之後核對實際的欄位名稱，並記錄顯示限制（Step 5）。 | 名稱與 probe 讀的不同：持倉 series 不會出現，done marker 不合 schema 時每次 run 結束都有 `TradingRunBindingInvalid`。名稱相同（producer 回報的情況）：binding 全部正常，面板把 ETH 數量標成 BTC |

## 硬性限制

rollout 文件「執行前必讀」的硬性限制全部適用，把其中的 `popdex-btc` 換成 `popdex-02`。這次最容易踩到的：

- **不得 start、stop、restart、enable 或 disable 任何 `tnauqquant@*` service 或 timer，不得修改 tnauqquant 的 config、env、run-state 或程式。** 本文件只讀取它們。lane 的啟動與 enable 由 Wan 決定。
- **順序固定為先 host、後中央。** PR 在時窗開始時才 merge；merge 之後 monitoring-prod 不得執行 `scripts/central-deploy`（包括為了其他變更），直到 Step 3 確認 `popdex-02` 已在 remote-write。
- **時間：** 本文件每個 `[CHANGE]` 步驟，包括 `scripts/central-deploy` 的 dry run 與正式部署，都不在 UTC 18:15–19:30 執行（18:30Z 是 Trading01 tnauqquant 的每日重啟 timer，19:00Z 是 monitoring-prod 的備份 cron）。引用 rollout 文件的段落時，時窗也以這一條為準。
- **Alloy 只 reload。** 不使用 `--restart-alloy`；`add` 要求它就是 STOP。
- **中止規則：** 只要在 Step 3 通過前停下（任何 STOP），下一次 `central-deploy` 之前，manager 先依 README 的 Remove 第 1 步用 `scripts/trading-target remove --server trading01 --strategy popdex-02` 開 PR 並 merge，master 不留沒有 probe 的 row。下次再用 `scripts/trading-target add` 加回。Step 2 已裝上的 probe 與 Alloy fragment 可以留著：
  - `prometheus/rules/trading.yml` 的告警全部以 inventory row 為條件，中央沒有 row 時不會為 `popdex-02` 觸發。
  - Loki 規則（`TradingExecutionIncident`、`TradingCriticalLogEvent`、`TradingCriticalWarnEvent`）直接比對收到的 log，不看 inventory。fragment 留著而 lane 寫出符合的事件時，仍會出現 shadow 告警；這不代表中央移除失敗。要連 log 一起停，用 `"$SETUP" retire --strategy popdex-02`。
- 不加 Alertmanager silence。所有 Trading 告警都是 `notification_mode="shadow"`，不會發 Telegram。
- 不要印出或複製 `popdex_02_config.yaml` 全文與 tnauqquant 的 env 檔，裡面可能有帳號資料或憑證。lane 的憑證在 `manager.env` 的 `TNAUQ_ENV_FILE` 指向的檔，**那個檔不得讀取**。本文件只取指定的單行；`/etc/tnauqquant/instances/popdex-02/manager.env` 也只取 `TNAUQ_EXPECTED_BIN` 那一行。

## Step 0 — Staging

照 rollout 文件的 Phase 0 原文執行（`MERGE` 是含本次變更的 master commit 完整 SHA，staging 目錄是 `/home/ubuntu/skyeye-staging/popdex-$M7`）。operator 機器上多確認一項：

```bash
git cat-file -e "$MERGE:agents/alloy/trading/deployment-linux-popdex-02.env.example" && echo MERGE-HAS-POPDEX-02
```

## Step 1 — 唯讀前置檢查與基準 `[READ-ONLY]`

唯一的寫入是 `$WORK`、`$CUT` 紀錄目錄。**Trading01 與 monitoring-prod 兩邊全部通過才進 Step 2；任何一項不符就 STOP**，依中止規則處理。

### Trading01（root shell）

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
- `PROBE-SAME` 或 `ACCESS-SAME` 沒印出：STOP。（`MERGE` 晚於加入 `TQ_BASE_ASSET` 的 commit 時，`probe.sh` 一定不同。）Trading01 上的共用 probe 檔案比 `MERGE` 舊，`add` 會以 `shared probe artifacts changed while …` 拒絕。更新共用檔案要先停下所有 `skyeye-trading-probe@*`（rollout 文件 Phase 3 的做法），會讓其他 strategy 的 probe 中斷，不在本文件範圍，由 manager 另行安排。`ensure-log-access.sh` 在 2026-11-14 rollout 之後改過，這一項很可能不符。

**lane 實際仍停用，是進入 Step 2 的條件。** `TQ_STRATEGY_DISABLED=1` 只讓 probe 回報 `run_expected=0`，擋不住 lane 啟動。

```bash
systemctl is-active tnauqquant@popdex-02.service  | tee "$WORK/lane.active"     # inactive
systemctl is-enabled tnauqquant@popdex-02.service | tee "$WORK/lane.enabled"    # disabled、masked 或 static
pgrep -a -f 'popdex_02_config' | tee "$WORK/lane.processes"                     # 沒有輸出
# timer 有兩個來源：已安裝的 unit file，以及 systemd 已載入的 timer unit。
# template 實際在用的 instance（例如 schedule@night.timer）只出現在後者
systemctl list-unit-files --type=timer --no-legend >"$WORK/timer-files" && [ -s "$WORK/timer-files" ] && echo TIMER-FILES-READ
systemctl list-units --type=timer --all --no-legend --plain >"$WORK/timer-units" && [ -s "$WORK/timer-units" ] && echo TIMER-UNITS-READ
awk '$1 !~ /[.]timer$/' "$WORK/timer-files" "$WORK/timer-units"                 # 沒有輸出
# 兩個來源合併，每個 timer 一行；template 的 unit file 另外看 popdex-02 這個 instance
{ awk '{ print $1 }' "$WORK/timer-files" | sed 's/@[.]timer$/@popdex-02.timer/'; awk '{ print $1 }' "$WORK/timer-units"; } |
  sort -u | while read -r t; do
    printf '%s triggers=%s enabled=%s active=%s\n' "$t" "$(systemctl show -p Triggers --value "$t")" \
      "$(systemctl is-enabled "$t" 2>&1)" "$(systemctl is-active "$t")"
  done | tee "$WORK/timers"
```

- 前三項都要符合註解。`is-active` 是 `active`、`activating` 或 `failed`，`is-enabled` 是 `enabled`、`enabled-runtime` 或其他值，都算不符。
- **兩個 timer 來源都要讀得到。** `TIMER-FILES-READ` 與 `TIMER-UNITS-READ` 都要印出（命令成功而且有內容），`awk` 那一行沒有輸出（每一行的第一欄都是 timer 名稱）。少一個標記、`awk` 有輸出，或 `timers` 有一行 `active=` 不是 `inactive` 而 `triggers=` 是空的（看不出它啟動什麼）：當作不符。
- **直接啟動這條 lane 的 timer：** `timers` 裡 `triggers=` 含 `tnauqquant@popdex-02.service` 的每一行，都必須是 `active=inactive`，而且 `enabled=` 是 `disabled`、`masked` 或 `static`。`enabled=enabled`、`enabled-runtime`（下次開機就會生效）或 `active=active` 算不符。已停用且 inactive 的 timer 不算不符。producer 回報這條 lane 有自己的 timer，目前 disabled、inactive，所以 `timers` 預期有 `tnauqquant@popdex-02.timer` 那一行，而且符合這一條。
- **共用的每日重啟（18:30Z），以及其他啟動對象會操作 tnauqquant instance 的 timer：** 在 `timers` 找到它。它已停用且 inactive 就不影響。它是啟用或 active 時，`triggers=` 是它啟動的 unit，用 `systemctl cat <unit>` 唯讀看它實際做什麼：只重啟已在跑的 instance（例如 `try-restart`），或對象不含 `popdex-02`，算符合；會讓停著的 `tnauqquant@popdex-02` 被啟動（`start` 或 `restart`，而且對象涵蓋它），算不符。看不出來就當作不符。
- 任何一項不符：**STOP，回報 Wan**。lane 已在跑或會被自動啟動，「Wan 手動測一個 cycle 之後才 enable」的前提不成立，後續由 Wan 決定。本文件不 stop、不 disable 任何 unit。

Lane 路徑與待核對的值：

```bash
ls -ld /home/ubuntu/tnauqquant /home/ubuntu/tnauqquant/config/popdex_02_config.yaml /home/ubuntu/tnauqquant/logs/live-runs
ls -ld /home/ubuntu/tnauqquant/run-state/popdex-02 2>&1 | tee "$WORK/run-state.before"    # 第一次 run 之前可能還不存在，只記錄
ls -1t /home/ubuntu/tnauqquant/logs/live-runs/ | grep '[.]raw[.]log$' | head -n 3           # 其他 lane 的檔名，只作參考
grep -nE '^[[:space:]]*instance_id:' /home/ubuntu/tnauqquant/config/popdex_02_config.yaml | tee "$WORK/config-instance-id"
systemctl show -p ExecStart --value tnauqquant@popdex-02.service | tee "$WORK/execstart"   # path=/usr/local/sbin/tnauqquant-service，參數是 launch popdex-02
LANE_ENV=/etc/tnauqquant/instances/popdex-02/manager.env                                   # tnauqquant-service install 寫出的 metadata
grep -c '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV"                                                 # 1
grep '^TNAUQ_EXPECTED_BIN=' "$LANE_ENV" | tee "$WORK/expected-bin"                         # 只取這一行，不看該檔其他內容
QUANT="$(sed -n 's/^TNAUQ_EXPECTED_BIN=//p' "$WORK/expected-bin" | tr -d "\"'")"; echo "$QUANT"
test -x "$QUANT" && echo QUANT-EXECUTABLE
grep -HE '^TQ_(EXECUTABLE|INSTANCE_ID)=' /etc/skyeye-trading/instances/*.env | tee "$WORK/sibling-identities"
```

- 前三個路徑缺任何一個：STOP，交給 tnauqquant manager。
- `live-runs` 裡現有的 raw log 屬於其他 lane，檔名只作參考，**不據此 STOP**（另一條 lane 的舊命名或備份檔不影響這次上線）。`popdex-02` 自己的命名在 Step 5 用它的 manifest 與實際 log 驗收。
- `TQ_INSTANCE_ID`：`config-instance-id` 要剛好一行（probe 只讀第一行），值是 `popdex-02` 就不必改 example。是別的值時，把 config 的值填進 SkyEye 的 env，並在執行紀錄寫下該值；**不要改 config**。值與 `sibling-identities` 任何一行的 `TQ_INSTANCE_ID` 相同、沒有這一行或有多行：STOP，交給 tnauqquant manager。
- `execstart` 只用來確認這條 lane 走共用的 launcher（producer 回報 `/usr/local/sbin/tnauqquant-service launch %i`）。**launcher 不是 `TQ_EXECUTABLE`**：它每條 lane 都相同，quant 程序的 image 也不是它。`execstart` 的 `path=` 不是 `/usr/local/sbin/tnauqquant-service` 時，主機與 producer 的回報不符：STOP，交給 tnauqquant manager。
- `TQ_EXECUTABLE`：這條 lane 的 quant binary，就是 `$QUANT`，取自 `$LANE_ENV` 的 `TNAUQ_EXPECTED_BIN`。`grep -c` 要是 `1`，`$QUANT` 要是絕對路徑，`QUANT-EXECUTABLE` 要印出。producer 回報的值是 `/home/ubuntu/tnauqquant/bin/popdex-02/quant`；`$QUANT` 是別的路徑，或上面任何一項不成立（`$LANE_ENV` 不存在時 `grep -c` 不會是 `1`）：STOP，請 tnauqquant manager 確認。
- `LANE_ENV` 的路徑由 tnauqquant 的原始碼決定，不必向 producer 詢問。來源是 tnauqquant `scripts/tnauqquant-service`（master `c53516a` 的行號）：第 31 行 `INSTANCE_INSTALL_ROOT="/etc/tnauqquant/instances"`，第 160 行 `MANAGER_ENV_PATH="$INSTANCE_INSTALL_ROOT/$INSTANCE/manager.env"`。它是 `tnauqquant-service install` 寫出的 metadata（`TNAUQ_EXPECTED_BIN`、`TNAUQ_ENV_FILE` 等）；tnauqquant 自己的 runbook（`docs/trading-server-runbook.md` 第 1146 行）也用 `grep -h` 從 `/etc/tnauqquant/instances/*/manager.env` 取 `TNAUQ_EXPECTED_BIN`。這裡只用上面兩個 `grep` 取那一行，不要 `cat`、不要用編輯器開。lane 的憑證放在 `TNAUQ_ENV_FILE` 指向的另一個檔，**那個檔不得讀取**。
- `$QUANT` 與 `sibling-identities` 任何一行的 `TQ_EXECUTABLE` 相同：STOP。`setup-linux.sh` 要求每個 instance 的 `TQ_EXECUTABLE` 各不相同，共用 binary 的 lane 目前裝不上去，需要 SkyEye 先改 installer。
- `TQ_EXECUTOR_MAP`：填 `popdex-main=popdex`。producer 回報 executor 名稱是 config 的 `routing.accounts[0].name`，值是 `popdex-main`（exchange `popdex_usdt_perp`）。在 `popdex_02_config.yaml` 唯讀確認 `routing.accounts` 只有這一個 account，只記下它的名稱。是別的名稱時填 config 的名稱，並在執行紀錄寫下與回報不同；找不到或有多個 account：STOP，請 tnauqquant manager 提供。
- executor 名稱與 `popdex-btc` 相同（config 照抄）並不衝突，不需要為了區分而改名：`TQ_EXECUTOR_MAP` 是每個 instance 自己的 env，probe 只讀自己這條 lane 的 raw log，輸出的 series 帶的是 `strategy` 與 `exchange`，沒有 executor 名稱；跨 lane 用 `strategy`／instance 區分。

填好 env 並 render（只寫 `$WORK`）：

```bash
install -m 600 "$STAGE/agents/alloy/trading/deployment-linux-popdex-02.env.example" "$WORK/popdex-02.env"
# 編輯 $WORK/popdex-02.env：填 TQ_EXECUTABLE=<$QUANT 的值> 與 TQ_EXECUTOR_MAP=popdex-main=popdex
# （config 的 executor 是別的名稱時用 config 的名稱）；
# config 的 instance_id 不是 popdex-02 時再改 TQ_INSTANCE_ID。其他不動
diff "$STAGE/agents/alloy/trading/deployment-linux-popdex-02.env.example" "$WORK/popdex-02.env"   # 只有上述兩行（或三行）不同
grep -c '^TQ_STRATEGY_DISABLED=1$' "$WORK/popdex-02.env"                                             # 1
"$SETUP" --render-only "$WORK/render" --env-file "$WORK/popdex-02.env" </dev/null || echo "STOP: render"
grep -c 'strategy *= *"popdex-02"' "$WORK/render/trading-popdex-02.alloy"                            # ≥ 1
```

### monitoring-prod（ubuntu）：安裝前的基準

Step 3 要拿它比對其他 lane 是否受 reload 影響，Step 4 失敗時 R5 要用它還原。`q`、`targets`、`t01_alerts` 與 rollout 文件 Phase 1 的同名函式相同。`probe_ages` 的 `age` 是現在與 probe 時間戳的差距**絕對值**，與 `TradingTelemetryMissing` 的算法相同，所以 probe 時間超前也算不新鮮。**本文件的新鮮門檻一律是 age < 60**（基準、Step 3、4b 與部署後檢查；告警本身是 180 秒）。

```bash
M7=<同上>; MERGE=<完整 SHA>
CUT="$HOME/popdex-02-onboarding-$M7"; install -d -m 700 "$CUT"
declare -p M7 MERGE CUT >"$CUT/vars"
cd /home/ubuntu/SkyEye
cat >"$CUT/helpers.sh" <<'EOF'
q() { curl -fsS --get http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -c '.data.result'; }
targets() { q 'trading_target_info' | jq -S '[.[].metric | del(.__name__)] | sort'; }
probe_ages() { q 'abs(time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production",server_id="trading01"})' \
  | jq -c '[.[] | {strategy: .metric.strategy, age: (.value[1] | tonumber | floor)}] | sort_by(.strategy)'; }
t01_alerts() { q 'ALERTS{product="tnauqquant",server_id="trading01",alertstate="firing"}' \
  | jq -c '[.[].metric | {alertname, strategy}] | sort'; }
EOF
. "$CUT/helpers.sh"

git rev-parse HEAD | tee "$CUT/old-head"
scripts/central-deploy --status 2>&1 | tee "$CUT/central-status-pre.log"   # Prometheus last reload successful: 1
targets | tee "$CUT/pre-targets.json"
jq -e 'map(select(.strategy == "popdex-02")) | length == 0' "$CUT/pre-targets.json"   # true
probe_ages | tee "$CUT/probe-ages.pre.json"          # Trading01 每個已安裝的 lane 一筆，age < 60，沒有 popdex-02
t01_alerts | tee "$CUT/t01-alerts.pre.json"
```

斷線重連時：`CUT="$HOME/popdex-02-onboarding-<M7>"; . "$CUT/vars"; . "$CUT/helpers.sh"; cd /home/ubuntu/SkyEye`。

- `probe_ages` 少了已安裝的 lane，或有一筆 age ≥ 60：既有 probe 已有問題，STOP，先查明。
- `jq` 印出 `false`：中央已提前部署 `popdex-02` row。記下時間，該段的 `TradingTelemetryMissing` 排除於 shadow 證據之外，照常繼續。此時 `old-head` 已含這個 row，R5-1 還原不了，之後要移除 row 時改走 README 的 Remove（先中央、後 host）。中央的 HEAD 與 applied SHA 都已是 `MERGE` 時，Step 4 走 4a 的「已套用」分支。

## Step 2 — Host：加入 `popdex-02` `[CHANGE Trading01]`

前提：Step 1 兩邊都通過，lane 仍停用，`$CUT` 的三個基準檔都已存好。

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
systemctl is-active tnauqquant@popdex-02.service; systemctl is-enabled tnauqquant@popdex-02.service   # 與 lane.active／lane.enabled 相同
```

`probe_timestamp_seconds` 在 `date +%s` 的 60 秒內，`run_expected 0`，`process_count 0`。

## Step 3 — 中央檢查：`popdex-02` 已在 remote-write（monitoring-prod）`[READ-ONLY]`

Step 2 完成後 2 分鐘內：

```bash
probe_ages | tee "$CUT/probe-ages.post-add.json"
jq -n -c --slurpfile pre "$CUT/probe-ages.pre.json" --slurpfile post "$CUT/probe-ages.post-add.json" '{
  siblings_same: (($pre[0] | map(.strategy)) == ($post[0] | map(select(.strategy != "popdex-02") | .strategy))),
  all_fresh: ($post[0] | all(.age < 60)),
  popdex_02: ($post[0] | any(.strategy == "popdex-02"))}'
q 'tnauqquant_run_expected{server_id="trading01",strategy="popdex-02"}' | jq -c '[.[].value[1]]'   # ["0"]
```

- `{"siblings_same":true,"all_fresh":true,"popdex_02":true}`：**通過，Step 4 才可以執行。**
- 2 分鐘內 `popdex_02` 仍是 `false` 或它的 age ≥ 60，其他 lane 正常：STOP，host 維持現狀，把輸出交給 manager，依中止規則處理。
- `siblings_same` 是 `false`，或其他 lane 的 age 從 < 60 變成 ≥ 60：在 Trading01 執行 `"$SETUP" retire --strategy popdex-02 </dev/null`，讓 Alloy 回到安裝前的 fragment 組合，再跑一次 `probe_ages`；然後 STOP，依中止規則處理。

## Step 4 — 中央 inventory：`scripts/central-deploy`（monitoring-prod）`[CHANGE monitoring-prod]`

前提：Step 3 已通過；現在不在 UTC 18:15–19:30；monitoring-prod 上沒有其他 operator。

### 4a — Dry run

```bash
cd /home/ubuntu/SkyEye
date -u +%H:%M                                           # 不在 18:15–19:30
scripts/central-deploy --dry-run --expect "${MERGE:?set MERGE first}" 2>&1 | tee "$CUT/central-deploy-dry-run.log"
```

看最後一行：

- `Dry run: validation passed; checkout left at … and nothing reloaded (…)`：進 4b。
- `Already up to date and applied at <MERGE 前 12 碼>; nothing to deploy`：中央的 HEAD 與 applied SHA 都已經是 `MERGE`（中央提前部署過，或 4b 已經成功、之後中斷重跑）。`central-deploy` 不會再做任何事，dry run 也不會印出 `validation passed`。**不執行 4b 的部署**，改做下面「已套用時的核對」。
- 其他：**STOP，不執行 4b**。拒絕原因的處理方式與 rollout 文件 Phase 5 的 dry run 相同（`--expect names …, but origin/master is …` 交給 manager；其他拒絕排除後在下一個時窗重跑 4a，不改用 `git pull`）。

**已套用時的核對**（只在上面第二種情況做）：

```bash
[ "$(git rev-parse HEAD)" = "$MERGE" ] && echo HEAD-IS-MERGE
scripts/central-deploy --status 2>&1 | tee "$CUT/central-status-applied.log" \
  | grep -cF "Checkout HEAD: ${MERGE:0:12}; last applied by central-deploy: ${MERGE:0:12}"   # 1
targets | jq -e 'any(.[]; .server_id == "trading01" and .strategy == "popdex-02")'           # true
probe_ages                                               # 每一筆（含 popdex-02）< 60
```

- 四項都符合：跳過 4b 的部署，直接做 4b 的「部署後檢查」。
- 任何一項不符：STOP，把輸出交給 manager。
- 走這條分支而需要移除 row 時（部署後檢查不通過，或之後中止），**不用 R5**：`$CUT/old-head` 可能已含這個 row，R5-1 還原不了。改走 README 的 Remove（先中央、後 host）。

### 4b — 正式部署

4a 通過之後才執行。先重新核對：

```bash
date -u +%H:%M                                           # 不在 18:15–19:30
probe_ages                                               # 每一筆（含 popdex-02）仍 < 60
tail -n 1 "$CUT/central-deploy-dry-run.log" | grep -q '^Dry run: validation passed' && echo DRY-RUN-OK
```

三項都符合才執行下一個區塊。時間已進入 18:15–19:30 就等時窗過後從 4a 重做；有一筆 age ≥ 60 就 STOP 查明；`DRY-RUN-OK` 沒印出就回到 4a。

```bash
scripts/central-deploy --expect "$MERGE" 2>&1 | tee "$CUT/central-deploy.log"; echo "rc=${PIPESTATUS[0]}"
```

- `rc=0` 且最後一行是 `central-deploy: done; applied <12 碼 SHA>`：成功，跑下面的檢查。
- `rc=0` 且最後一行是 `Already up to date and applied at …`：前一次已經套用（例如斷線前那一次其實成功了）。照 4a 的「已套用時的核對」處理。
- 其他結果依 rollout 文件 Phase 5 判讀：`Checkout fast-forwarded` 之前失敗，中央沒有變更，STOP；之後失敗執行 R5；訊息含 `is published but not loaded` 時不 rollback，排除原因後重跑部署那一行。不要改用 `git pull` 或 `git reset --hard`。

部署後檢查：

```bash
[ "$(git rev-parse HEAD)" = "$MERGE" ] && echo HEAD-IS-MERGE
sleep 70
jq -S '. + [{"environment":"production","notification_mode":"shadow","product":"tnauqquant","quote_currency":"USDT","server_id":"trading01","strategy":"popdex-02"}] | unique' \
  "$CUT/pre-targets.json" >"$CUT/expected-targets.json"
targets | tee "$CUT/post-targets.json"
diff "$CUT/expected-targets.json" "$CUT/post-targets.json" && echo TARGETS-OK
q 'trading_target_info{server_id="trading01"} unless on (product, environment, server_id, strategy) (abs(time() - tnauqquant_probe_timestamp_seconds{product="tnauqquant",environment="production"}) < 60)'   # []
t01_alerts | tee "$CUT/t01-alerts.post-deploy.json"
```

`unless` 查詢是 `TradingTelemetryMissing` 的算式（inventory row 找不到時間差絕對值在門檻內的 probe），範圍是 Trading01 的 row，門檻用本文件的 60 秒。

- `HEAD-IS-MERGE` 沒印出：checkout 被移動過，停下，把 `git log --oneline "$MERGE..HEAD"` 交給 manager。
- `TARGETS-OK` 沒印出，或 `unless` 查詢不是 `[]`：執行 rollout 文件的 [R5](trading01-popdex-rollout.md#r5--中央-inventory-退回)，把 `popdex-btc` 換成 `popdex-02`。R5 讀的 `$CUT/old-head`、`$CUT/pre-targets.json` 與 `targets` 就是 Step 1 存下與定義的。`old-head` 已含 `popdex-02` row 時（Step 1 的 `jq` 印出 `false`，或走了 4a 的已套用分支）不用 R5，改走 README 的 Remove（先中央、後 host）。
- lane 停著且 disabled 時，`popdex-02` 預期沒有任何 firing 告警；其他 lane 的告警與 `t01-alerts.pre.json` 相同。

## Step 5 — Wan 手動測試 cycle 之後的唯讀核對 `[READ-ONLY]`

Wan 跑完手動測試 cycle 之後、lane 正式 enable 之前，在 Trading01（root，`. "$WORK/vars"`）核對。先看 manifest：

```bash
ENVF=/etc/skyeye-trading/instances/popdex-02.env
MAN=/home/ubuntu/tnauqquant/run-state/popdex-02/current.json
DONE=/home/ubuntu/tnauqquant/run-state/popdex-02/current.done.json
PROM=/var/lib/skyeye-trading/textfile/tnauqquant-popdex-02.prom
test -f "$MAN" && echo MANIFEST-PRESENT
jq -r '.executable, .instance_id, .strategy, .log_path' "$MAN"
grep -E '^TQ_(EXECUTABLE|INSTANCE_ID|STRATEGY|EXECUTOR_MAP|RAW_LOG_GLOB)=' "$ENVF"
grep -nE '^[[:space:]]*instance_id:' /home/ubuntu/tnauqquant/config/popdex_02_config.yaml
```

- `MANIFEST-PRESENT` 沒印出：這次 cycle 沒有寫出 runtime contract，下面無法核對。STOP，回報 Wan 與 tnauqquant manager；這樣 enable 的話 lane 會是 `TradingRuntimeContractMissing`。
- `.executable` 必須等於 `TQ_EXECUTABLE`（quant binary，不是 launcher）；`.instance_id` 必須同時等於 `TQ_INSTANCE_ID` 與 config 的 `instance_id:`。只有 SkyEye env 填錯時，改 `$WORK/popdex-02.env` 後照 Step 2 的 `add` 重跑一次（就地更新，Alloy 只 reload）。manifest 與 config 互相不符，或 `.strategy` 不是 `popdex-02`：STOP，交給 tnauqquant manager。

manifest 核對過之後，先確認它的 `.log_path` 就是 `TQ_RAW_LOG_GLOB` 選得到的檔案，不要自己用萬用字元挑檔：

```bash
LOG="$(jq -r '.log_path' "$MAN")"; RUN_ID="$(jq -r '.run_id' "$MAN")"
[ "$(basename "$LOG")" = "$RUN_ID.raw.log" ] &&
  compgen -G "$(sed -n 's/^TQ_RAW_LOG_GLOB=//p' "$ENVF" | tail -n 1)" | grep -qxF "$LOG" &&
  echo "LOG-MATCHES-GLOB run_id=$RUN_ID"
```

沒印出 `LOG-MATCHES-GLOB`：這條 lane 的 log 不是 contract 的命名（檔名不是 `<run_id>.raw.log`，或 glob 選不到它），Alloy 不會收它，probe 也不會把它算進當日 cycle。**STOP，不要執行下一個區塊**，回報 manager，不要自己放寬 glob。

印出之後才讀 `$LOG`：

```bash
grep -oE '(^|[[:space:]])executor=[^[:space:]]+' "$LOG" | sort | uniq -c
# probe 採用的那一筆：最後一筆 msg=pnl_status 且 stable=true
PNL="$(awk '{ m = s = ""; for (i = 1; i <= NF; i++) { e = index($i, "="); if (!e) continue
    k = substr($i, 1, e - 1); v = substr($i, e + 1); gsub(/^"|"$/, "", v); if (k == "msg") m = v; if (k == "stable") s = v }
  if (m == "pnl_status" && s == "true") last = $0 } END { if (last != "") print last }' "$LOG")"
grep -oE '(^|[[:space:]])(time|volume_usd_by_executor)=[^[:space:]]+' <<<"$PNL"
grep -oE '(net|initiator|carrier)_qty_[a-z0-9]+=' "$LOG" | sort | uniq -c
if [ -e "$DONE" ]; then jq '{long_btc, short_btc, net_btc, dust_tolerance_btc}' "$DONE"; else echo NO-DONE-MARKER; fi
grep -E '^tnauqquant_(process_identity_ok|strategy_identity_ok|config_snapshot_match|log_binding_ok|marker_binding_ok|current_run_exchange_volume_usd|current_position_btc|current_net_position_btc)[{]' "$PROM"
```

- **log 進 Loki：** 到 monitoring-prod，在 cycle 結束後一小時內，用 Trading01 印出的 `run_id` 查這一次 run（`run_id` 是 stream label）：

  ```bash
  RUN_ID=<Trading01 印出的 run_id>
  RESP="$(curl -fsS --get http://127.0.0.1:3100/loki/api/v1/query --data-urlencode \
    "query=sum(count_over_time({product=\"tnauqquant\",server_id=\"trading01\",strategy=\"popdex-02\",run_id=\"$RUN_ID\"}[1h]))")" &&
    jq -e '.status == "success" and (.data.result | length == 1 and (.[0].value[1] | tonumber) > 0)' <<<"$RESP" >/dev/null &&
    echo LOKI-HAS-THIS-RUN
  ```

  完整回應先存進 `RESP`，`curl` 的退出碼是 0 才往下驗同一份回應。印出 `LOKI-HAS-THIS-RUN` 才算通過：`curl` 成功、回應的 `status` 是 `success`，而且這個 `run_id` 的 log 筆數大於 0。沒印出就不算通過，不論是查詢失敗或傳輸中斷（`curl` 退出碼不是 0）、API 沒有回報成功、沒有這個 run 的 stream，還是筆數為 0；回報 manager。
- **executor 映射：** raw log 的 `executor=` 必須是 `TQ_EXECUTOR_MAP` 等號左邊的名稱（producer 回報 `popdex-main`）。成交額要從 probe 採用的那一筆讀：上面 `PNL` 那一行的 `volume_usd_by_executor`，該 executor 的金額要與 `current_run_exchange_volume_usd{exchange="popdex"}` 一致。之後若還有 `stable` 不是 `true` 的 `pnl_status`，probe 不採用，不要拿它比。probe 只採用時間可信的行（`time=` 是 RFC 3339，且不晚於 probe 取樣時間加 120 秒），這裡的命令與下面的加總都不做這項篩選；命令結果與 probe 輸出不符時，先看印出的 `time=`，不要據此修改 env，回報 manager。
  - 那一筆沒有 `volume_usd_by_executor`（或整份 log 沒有 stable 的 `pnl_status`）時，probe 才改成加總 `msg=trade_status` 的 `volume_usd`。這時用同樣的加總核對：

    ```bash
    awk '{ m = x = v = ""; for (i = 1; i <= NF; i++) { e = index($i, "="); if (!e) continue
        k = substr($i, 1, e - 1); f = substr($i, e + 1); gsub(/^"|"$/, "", f); if (k == "msg") m = f; if (k == "executor") x = f; if (k == "volume_usd") v = f }
      if (m == "trade_status" && v ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) sum[x] += v } END { for (x in sum) printf "%s %.10f\n", x, sum[x] }' "$LOG"
    ```

  - raw 的 executor 名稱不是 `TQ_EXECUTOR_MAP` 等號左邊的名稱，才是映射填錯（probe 的成交額會是 `0`）：改 `$WORK/popdex-02.env` 後照 Step 2 的 `add` 重跑一次。名稱相符而金額不符時不改 env，照上面那一句回報 manager。這次 cycle 沒有成交時，成交額無法驗證，在執行紀錄註明。
- **done marker：** 印出 `NO-DONE-MARKER` 時，這次 cycle 沒有寫 terminal marker，`marker_binding_ok` 仍是 `1`，這不是 schema 錯誤；記下 cycle 是怎麼結束的。marker 存在時才看 schema：四個欄位任何一個是 `null`，或 `marker_binding_ok 0`，共用 probe 就無法綁定這條 lane 的 marker。**不要改 probe，回報 manager**，lane enable 之前要先決定。
- **數量欄位名稱：** producer 回報欄位名稱沒有改，仍是 `*_btc`。上面的 `grep` 印出的不是 `*_qty_btc` 時，主機與回報不符，probe 讀不到持倉，回報 manager。
- **數量單位：** producer 已確認：欄位名是 `*_btc`，值是 ETH 數量（config 的 `execution.quantity`，`quantity_unit: base`，這條 lane 的 base 是 ETH）。binding 不檢查單位，probe 也不換算，所以要記錄顯示限制。執行紀錄寫「`popdex-02` 的持倉顯示的是 ETH 數量，標示卻是 BTC（策略詳情的「目前持倉 · 多空方向」與策略總覽表格的「淨部位」欄），不能與 BTC lane 的持倉相加或比較」，依據寫「producer 確認（tnauqquant manager 回報）」。
  - 可以另外交叉確認，不是必要步驟：測試 cycle 持倉不為零、Wan 知道交易所實際持倉時，對照當下的 `tnauqquant_current_position_btc`（cycle 結束後持倉是 0，看不出單位）。對不上 ETH 數量時回報 manager。

  本文件不改 dashboard 與共用 probe。ETH 單位的修正（`TQ_BASE_ASSET`）另依 [README 的 Position units](../agents/alloy/trading/README.md#position-units-tq_base_asset) 上線；上線後上面這條顯示限制即解除。
- 五個 `…_ok`／`config_snapshot_match` 都是 `1`，上面每一項都有結論，才算核對完成。

## 正式 enable 之前：把 `TQ_STRATEGY_DISABLED` 改回 `0` `[CHANGE Trading01]`

Step 5 核對完成、回報 manager 的事項都有結論之後，Wan 決定 enable lane 時，在 lane 啟動**之前**執行（不在 UTC 18:15–19:30）：

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
| Wan 的手動測試 cycle（`max_cycles=1`）跑超過 2 分鐘 | `TradingUnexpectedProcess`，程序結束後消失。這就是 disabled 的 lane 被啟動時應有的訊號 |
| 測試 cycle 結束時沒有寫 done marker | 沒有。marker 不存在不算 binding 錯誤，留下的 `running` manifest 在 disabled 期間也不算 ProcessDown |
| 測試 cycle 以 `risk_halt`、`max_cycles_drain_failed` 或無法辨識的 reason 結束 | `TradingCriticalSafetyState`（此時不再顯示 `TradingUnexpectedProcess`）；`pnl_status` 回報 `risk_stopped=true` 時另有 `TradingRiskStopped`。這是 lane 的真實狀態，交給 Wan |
| manifest 存在但 binding 不成立 | `TradingRunBindingInvalid`（不看 `run_expected`）。原因可能是 `TQ_EXECUTABLE`／`TQ_INSTANCE_ID` 填錯、config 在 run 開始後被改，或 done marker **存在**但欄位不合 schema、與 manifest 不符。依 Step 5 核對 |
| 中央比 host 先部署，或 probe 停超過 180 秒 | `TradingTelemetryMissing` |

disabled 期間**不會**出現 `TradingProcessDown`、`TradingRuntimeContractMissing`、`TradingPnlTelemetryStale`，它們都要求 `run_expected=1`。

改回 `TQ_STRATEGY_DISABLED=0` 之後、lane 啟動之前，看 run-state 留下什麼：

| run-state 的狀態 | `popdex-02` 的告警 |
|---|---|
| 沒有 manifest | `TradingRuntimeContractMissing`（30 秒後）；P&L 持續無效滿 3 分鐘再加上 `TradingPnlTelemetryStale`。**不會**有 `TradingProcessDown`：沒有 manifest 時 binding 是 0，規則的 `unless` 把它抑制 |
| 有效的 `running` manifest，沒有 done marker | `TradingProcessDown`（2 分鐘後）；最後一筆 `pnl_status` 超過 5 分鐘或無效時，滿 3 分鐘再加上 `TradingPnlTelemetryStale` |
| 有效的 manifest，加上與它相符的 done marker | 沒有，marker 讓 `run_expected=0`。reason 屬於上表那三種時是 `TradingCriticalSafetyState` |
| manifest 在，done marker 存在但不合 schema 或與 manifest 不符 | `TradingRunBindingInvalid`；`TradingProcessDown` 被抑制；P&L 過期時另有 `TradingPnlTelemetryStale` |

lane 啟動並寫出新的 manifest 與有效的 `pnl_status` 之後，這些告警消失。

Step 2 到 Step 4 的 UTC 時窗，以及 Wan 的手動測試 cycle，都寫進執行紀錄，並從 `trading01`／`popdex-02` 的 shadow 證據中排除。

## 執行紀錄

| 項目 | 時間（UTC） | 結果／record |
|---|---|---|
| Step 0 staging | | `MERGE`、`STAGE` |
| Step 1 前置檢查與基準 | | `WORK`、`CUT`、Alloy 版本、lane 停用的核對結果、填入的 `TQ_EXECUTABLE`／executor 名稱／`TQ_INSTANCE_ID` 及其來源（與 producer 回報不同時註明） |
| Step 2 host add | | `Rollback record:` 路徑、`rc` |
| Step 3 中央檢查 | | 比對結果、`popdex-02` 的 age |
| Step 4a dry run | | 最後一行；走「已套用」分支時另記四項核對結果 |
| Step 4b central-deploy | | applied SHA、`TARGETS-OK` |
| Step 5 測試 cycle 後核對 | | 五個 binding 值、`run_id`、log 檔名與 Loki、executor 與成交額、done marker、數量欄位名稱、單位的顯示限制（照 Step 5 的句子寫；有做交叉確認時記結果） |
| `TQ_STRATEGY_DISABLED=0` | | `Rollback record:` 路徑 |
