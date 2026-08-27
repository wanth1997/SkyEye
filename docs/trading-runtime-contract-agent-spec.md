# tnauqquant Trading Run Contract Implementation Spec

> **Copy/paste handoff:** 將本文件完整貼給負責 tnauqquant 的 agent。該 agent 不需要本次對話的其他內容。
>
> **For agentic workers:** Use a dedicated worktree from the latest `origin/master`. Implement task-by-task with tests first. Do not touch a live process, sidecar, exchange, credential, or real order.

**Goal:** 讓既有 `scripts/tq live run --human <config>` 在不改變 operator 啟動方式的前提下，為 SkyEye 產生可驗證的 run manifest 與 structured done marker，使 PID、config、log、run identity 與完成原因能可靠綁定。

**Architecture:** `scripts/tq` 仍負責 preflight、build、foreground pipeline 與 raw log path，並透過環境變數把 run contract 傳給 quant。Quant 在任何 executor/exchange I/O 前，以實際 PID 與載入後 config 寫出 immutable manifest；Engine 在 safe completion 或 critical safety state 時，以同一 binding 寫 structured JSON marker。未提供完整 run contract 的 direct quant/watchdog 路徑維持既有 legacy marker 格式與行為。

**Tech Stack:** Go standard library、Bash、現有 tnauqquant config/engine/runtime、JSON schema version 1。

## 1. User Authorization and Hard Boundaries

Owner 已核准修改 Trading repo，但授權範圍只包含 runtime metadata 與 monitoring contract。

### In scope

- `scripts/tq live run --human` 產生 run ID、state paths 與 launch lock。
- Quant 寫 actual PID、process start time、canonical paths、full config SHA-256。
- Engine 寫 atomic JSON done marker，保留完成/critical reason。
- 新增 hermetic tests、schema fixtures、runbook 與 project/work-log 更新。

### Forbidden

- 不得修改 signal、policy、router、tactic、executor、risk threshold 或交易策略。
- 不得修改下單、平倉、reconcile、PNL 計算或 `pnl_status` 語意。
- 不得順便改成 JSON logging，不得新增 `/metrics`。
- 不得將 watchdog 改成正式 execution mode，不得增加 auto-restart。
- 不得啟動、停止、signal 或 attach 真實 trading process/sidecar。
- 不得讀取、複製、輸出或提交 `.env`、API keys、exchange credentials。
- 不得使用真實 config/log 作測試 fixture；測試只能使用 synthetic temp directories。
- 不得改動 GoExchange dependency 或安裝新 package。

## 2. Repository and Worktree Gate

目前 primary tnauqquant worktree 有既存未提交變更，不能直接使用。開始前執行：

```bash
cd /Users/tinghsu/projects/tnauqquant
git worktree list --porcelain
git branch --show-current
git status --short --branch
git fetch origin
git worktree add -b feat/trading-run-contract \
  /Users/tinghsu/projects/tnauqquant-trading-run-contract origin/master
cd /Users/tinghsu/projects/tnauqquant-trading-run-contract
```

若 branch 或 worktree path 已存在，停止並回報，不得重用另一個 agent 的 branch/worktree。進入 worktree 後先完整閱讀：

```text
AGENTS.md
docs/project-brief.md
docs/work-log.md
scripts/tq
scripts/tq_test.sh
cmd/quant/main.go
cmd/quant/main_test.go
engine/engine.go
engine/engine_test.go
scripts/watchdog.sh
scripts/watchdog_test.sh
docs/trading-server-runbook.md
```

## 3. Existing Behavior That Must Remain True

- `scripts/tq live run --human config/...yaml` 在 foreground 執行。
- Raw log 命名是 `logs/live-runs/YYYYMMDD_HHMMSS_<config-stem>.raw.log`。
- Pipeline exit precedence 保持 quant → tee → logview 的既有行為。
- Build subprocess 不得繼承 trading secrets；runtime quant 仍需繼承 `.env`。
- MEXC UI config 的 pinned sidecar source/runtime identity preflight 必須保留且仍在 build 前 fail-fast。
- Direct `bin/quant` 或 watchdog 只有 `TQ_DONE_MARKER`、沒有完整 contract 時，維持 legacy key/value marker。
- Watchdog 只以 marker 是否存在阻止 restart；其現有 tests 必須繼續通過。
- `risk_halt` 寫 marker但不一定停止 process。
- `max_cycles_complete` 與 `reduce_only_complete` 是 safe completion。
- `max_cycles_drain_failed` 是 critical failure 並要求 error stop。

## 4. Exact Version 1 Contract

### 4.0 Completed-cycle P&L event compatibility

SkyEye 的跨 run 歷史圖不改動 P&L 公式，只消費既有 completed-cycle log contract。每次完成 cycle 的 authoritative event 必須同時包含：

```text
time=<RFC3339Nano>
msg=pnl_status
stable=true
cycle_completed=true
cycle_id=<process-scoped unique id>
cycle_real_pnl_usdt=<rebate-adjusted delta for this cycle>
```

`real_pnl_usdt` 仍是單一 session 的 cumulative 值，不能拿來跨 run 直接相加。SkyEye 以 raw-log basename 作 run identity，再以 `(run identity, cycle_id)` 去重 `cycle_real_pnl_usdt`；同一 process-scoped cycle 的完全相同重複 log 可忽略，內容衝突則 fail closed。缺少任一必要欄位的 legacy record 不得猜測或 backfill，只能排除並顯示 coverage gap。

### 4.1 Environment variables passed only to quant

`scripts/tq live run --human` 必須在 quant process environment 設定：

| Variable | Value |
|---|---|
| `TQ_RUN_ID` | raw log basename 移除 `.raw.log` |
| `TQ_STRATEGY` | `.env` 明確值；同時作為 structured monitoring contract 的 opt-in |
| `TQ_RUN_MANIFEST` | `<TQ_RUN_STATE_ROOT>/<strategy>/current.json` |
| `TQ_RUN_LOG_PATH` | raw log canonical absolute path |
| `TQ_DONE_MARKER` | `<TQ_RUN_STATE_ROOT>/<strategy>/current.done.json` |

`TQ_RUN_STATE_ROOT` 是 launcher-only override，預設 `$TNAUQ_ROOT/run-state`。只有 `TQ_STRATEGY` 非空時才啟用 structured contract；未設定時 human run 完全維持既有 raw-log-only 行為。實際 monitored config 的 untracked `.env` 會設定：

```bash
TQ_STRATEGY=mexc-toobit-btc
```

不得把 `TQ_STRATEGY` 或任何新值寫入 tracked real config。

### 4.2 State layout

```text
run-state/
└── mexc-toobit-btc/
    ├── .launch.lock/
    │   └── owner
    ├── current.json
    ├── current.done.json
    └── archive/
```

- `run-state/` 必須加入 repo `.gitignore`。
- State directory mode `0700`，manifest/marker mode `0600`。
- `.launch.lock` 使用 atomic `mkdir`；lock 維持到 foreground pipeline 結束。
- `current.json` 或 `current.done.json` 已存在時，launcher 必須在 build/quant 前 fail closed。
- Launcher 不自動刪除或覆蓋舊 state。
- 正常結束後 operator 先檢查，再把 current files 移到 timestamped `archive/` directory；critical/incomplete run 也只能人工 archive。
- Manifest 本身存在但 process 不存在代表 incomplete/crashed run，不能被下一輪靜默覆蓋。

### 4.3 Go public types

Create `internal/runstate/runstate.go` with these exact exported types and JSON names:

```go
package runstate

const SchemaVersion = 1

type Binding struct {
	SchemaVersion int    `json:"schema_version"`
	RunID         string `json:"run_id"`
	Strategy      string `json:"strategy"`
	InstanceID    string `json:"instance_id"`
	PID           int    `json:"pid"`
	ConfigSHA256  string `json:"config_sha256"`
}

type Identity struct {
	Binding
	ProcessStartedAt string `json:"process_started_at"`
	Executable       string `json:"executable"`
	ConfigPath       string `json:"config_path"`
	LogPath          string `json:"log_path"`
	DoneMarkerPath   string `json:"done_marker_path"`
}

type Manifest struct {
	Identity
	State string `json:"state"`
}

type DoneMarker struct {
	Binding
	Reason           string  `json:"reason"`
	Phase            string  `json:"phase"`
	CompletedAt      string  `json:"completed_at"`
	LongBTC          float64 `json:"long_btc"`
	ShortBTC         float64 `json:"short_btc"`
	NetBTC           float64 `json:"net_btc"`
	DustToleranceBTC float64 `json:"dust_tolerance_btc"`
	Error            string  `json:"error,omitempty"`
}
```

Required API:

```go
func ValidateIdentity(identity Identity) error
func WriteManifest(path string, manifest Manifest) error
func WriteDoneMarker(path string, marker DoneMarker) error
func IsCriticalReason(reason string) bool
```

Validation rules:

- `schema_version == 1`。
- `run_id` matches `^[0-9]{8}_[0-9]{6}_[A-Za-z0-9._-]+$`。
- `strategy` matches `^[a-z0-9][a-z0-9.-]*$`。
- `instance_id` non-empty and respects existing config validation。
- PID > 0。
- SHA-256 is exactly 64 lowercase hex characters。
- Times parse with `time.RFC3339Nano`。
- Executable/config/log/marker paths are absolute。
- Manifest `state` is exactly `running` and remains immutable；done marker determines safe/critical outcome。

### 4.4 Manifest fixture

Create `docs/contracts/fixtures/run-manifest.v1.json` with this deterministic content:

```json
{
  "schema_version": 1,
  "run_id": "20260717_024506_mexc_toobit_btc_config",
  "strategy": "mexc-toobit-btc",
  "instance_id": "mexc-toobit-btc-initiator-hedge",
  "pid": 12345,
  "config_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "process_started_at": "2026-07-17T02:45:06Z",
  "executable": "/srv/tnauqquant/quant",
  "config_path": "/srv/tnauqquant/config/mexc_toobit_btc_config.yaml",
  "log_path": "/srv/tnauqquant/logs/live-runs/20260717_024506_mexc_toobit_btc_config.raw.log",
  "done_marker_path": "/srv/tnauqquant/run-state/mexc-toobit-btc/current.done.json",
  "state": "running"
}
```

### 4.5 Done marker fixture

Create `docs/contracts/fixtures/done-marker.v1.json`:

```json
{
  "schema_version": 1,
  "run_id": "20260717_024506_mexc_toobit_btc_config",
  "strategy": "mexc-toobit-btc",
  "instance_id": "mexc-toobit-btc-initiator-hedge",
  "pid": 12345,
  "config_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "reason": "max_cycles_complete",
  "phase": "max_cycles_complete",
  "completed_at": "2026-07-17T16:20:00Z",
  "long_btc": 0,
  "short_btc": 0,
  "net_btc": 0,
  "dust_tolerance_btc": 0
}
```

### 4.6 Reason and overwrite semantics

| reason | Classification | Marker precedence |
|---|---|---|
| `max_cycles_complete` | safe | May write only when no critical marker exists |
| `reduce_only_complete` | safe | May write only when no critical marker exists |
| `risk_halt` | critical | First critical marker wins |
| `max_cycles_drain_failed` | critical | First critical marker wins |
| any unrecognized value | critical/unknown to SkyEye | First critical marker wins |

`WriteDoneMarker` behavior:

1. No existing marker: validate and atomic write。
2. Existing marker from another run/config/PID: return error and do not overwrite。
3. Existing critical marker: preserve it and return nil for later same-run writes。
4. Existing safe marker followed by critical marker: critical marker atomically replaces safe marker。
5. Existing safe marker followed by same safe reason: idempotent success。
6. Existing safe marker followed by a different safe reason: return error and preserve the first outcome。
7. Corrupt existing JSON: return error and preserve file。

`WriteManifest` must reject an existing destination file rather than overwrite it, even when its JSON looks valid。

Atomic writer requirements:

- Create temp file in destination directory。
- Encode JSON with two-space indentation and trailing newline。
- `Chmod(0600)`、`Sync()`、`Close()`、`Rename()`。
- Remove temp file on every error path。
- Do not log JSON payload or environment values。

### 4.7 SkyEye state precedence

The Trading agent does not implement metrics, but its contract must support this exact consumer behavior:

```text
critical marker > duplicate process > binding invalid > unexpected/down > safe completion > running
```

- Manifest + live matching PID + no marker = expected running。
- Matching safe marker = completed; process absence is not ProcessDown。
- Matching critical marker = critical regardless of whether PID still exists。
- Manifest with no marker + missing PID = down/incomplete。
- Marker binding mismatch = fail closed; marker cannot suppress down alert。

## 5. Exact File Plan

### Create

```text
internal/runstate/runstate.go
internal/runstate/runstate_test.go
docs/trading-run-contract.md
docs/contracts/fixtures/run-manifest.v1.json
docs/contracts/fixtures/done-marker.v1.json
```

### Modify

```text
.gitignore
scripts/tq
scripts/tq_test.sh
cmd/quant/main.go
cmd/quant/main_test.go
engine/engine.go
engine/engine_test.go
docs/trading-server-runbook.md
docs/max-cycles-flat-to-flat-drain-design.md
docs/project-brief.md
docs/work-log.md
```

Do not modify files outside this list unless a compile/test failure proves a direct dependency. Report the dependency before expanding scope.

## 6. Implementation Tasks

### Task 1: Atomic runstate package

**Tests first:** `internal/runstate/runstate_test.go`

- [ ] Add validation tests for every required Binding/Identity field。
- [ ] Add manifest write/JSON round-trip test with exact fixture-equivalent fields。
- [ ] Assert file mode is `0600` and output ends with newline。
- [ ] Add marker first-write and idempotent same-safe-reason tests。
- [ ] Add different-run rejection test。
- [ ] Add corrupt-existing-marker preservation test。
- [ ] Add critical-over-safe and critical-not-downgraded tests。
- [ ] Run tests and capture RED evidence before implementation。

Run:

```bash
go test ./internal/runstate -count=1
```

Expected before implementation: package or symbols missing. Implement the API from section 4.3 with standard library only, then rerun until PASS.

Commit:

```bash
git add internal/runstate/runstate.go internal/runstate/runstate_test.go \
  docs/contracts/fixtures/run-manifest.v1.json \
  docs/contracts/fixtures/done-marker.v1.json
git commit -m "feat: add atomic trading run state contract"
git fetch origin
git rebase origin/master
```

### Task 2: TQ human launcher contract

**Tests first:** extend `scripts/tq_test.sh` without real config or commands.

Required new tests:

- [ ] Human run exports all five contract variables to fake quant。
- [ ] `TQ_RUN_ID` exactly equals raw-log basename without `.raw.log`。
- [ ] `TQ_STRATEGY=mexc-toobit-btc` opts into contract, survives safe env loading and reaches quant only at runtime。
- [ ] Build subprocess still reports all trading/run secrets absent。
- [ ] Existing `current.json` refuses before build/quant。
- [ ] Existing `current.done.json` refuses before build/quant。
- [ ] Existing `.launch.lock` refuses a second launch。
- [ ] State/lock directory is created with owner-only permissions。
- [ ] Lock is removed after fake foreground pipeline returns。
- [ ] Quant/tee/logview exit precedence is unchanged。
- [ ] Human run without `TQ_STRATEGY` remains raw-log-only and backward compatible。
- [ ] Plain non-human `live run` remains backward compatible and does not require contract files。

Update fake quant in `install_fake_tools()` to record names and non-secret values for:

```text
TQ_RUN_ID
TQ_STRATEGY
TQ_RUN_MANIFEST
TQ_RUN_LOG_PATH
TQ_DONE_MARKER
```

Never record `.env` values unrelated to this allowlist.

Run RED/GREEN:

```bash
bash scripts/tq_test.sh
```

Implementation requirements in `scripts/tq`:

- Add `TQ_RUN_STATE_ROOT` and `TQ_STRATEGY` opt-in semantics to help text。
- Keep current sidecar/config preflight ordering。
- When `TQ_STRATEGY` is empty, execute the current human pipeline without contract state。
- When `TQ_STRATEGY` is set, generate raw log first, then run ID, then state paths。
- Validate non-empty strategy with `^[a-z0-9][a-z0-9.-]*$`。
- Acquire atomic lock before checking/writing current state and before build。
- Refuse existing state with a message that tells operator to inspect and archive; never `rm` it。
- Apply contract env assignments only to the quant command in the first pipeline segment。
- Always release launch lock on normal pipeline return; stale current manifest still prevents unsafe relaunch after abrupt shell death。

Commit:

```bash
git add scripts/tq scripts/tq_test.sh .gitignore
git commit -m "feat: bind human live runs to monitoring state"
git fetch origin
git rebase origin/master
```

### Task 3: Quant writes actual manifest before exchange I/O

**Tests first:** add focused tests to `cmd/quant/main_test.go` for this exact helper:

```go
func prepareRunContract(
	cfgPath string,
	cfg *config.Config,
	startedAt time.Time,
) (*runstate.Identity, error)
```

Behavior:

- If `TQ_RUN_MANIFEST` is empty, return `(nil, nil)` and keep direct/watchdog compatibility。
- If it is set, require `TQ_RUN_ID`、`TQ_STRATEGY`、`TQ_RUN_LOG_PATH`、`TQ_DONE_MARKER`。
- Canonicalize executable/config/log/marker paths to absolute paths。
- Compute full 64-hex SHA-256 from the loaded config file; do not reuse `fileSHA256Short()`。
- Use `os.Getpid()` and the `startedAt` captured at the first line of `main()`。
- Use `cfg.InstanceID`; empty instance ID is an error for a monitored contract。
- Validate identity, write `Manifest{Identity: ..., State: "running"}`, and return a copy of the identity。
- Any partial/invalid contract returns an error before signal/executor creation。

Main wiring order:

```text
capture processStartedAt
parse flags
load config
initialize logger
log build/config snapshot
prepareRunContract
create context/signal/executors/router/risk/engine
```

On error use existing fatal logging with message `run_contract_prepare_failed`. Pass returned identity into `engine.Config.RunIdentity`. Keep `DoneMarkerPath: os.Getenv("TQ_DONE_MARKER")` unchanged.

Run:

```bash
go test ./cmd/quant -run 'TestPrepareRunContract' -count=1
```

Commit together with Task 4 after engine wiring compiles.

### Task 4: Structured engine marker with legacy fallback

Add to `engine.Config`:

```go
RunIdentity *runstate.Identity
```

`writeDoneMarker` must branch:

```text
RunIdentity == nil → execute current legacy key/value code unchanged
RunIdentity != nil → construct runstate.DoneMarker and call runstate.WriteDoneMarker
```

Structured marker fields:

- Binding is copied exactly from `RunIdentity.Binding`。
- Reason/phase and inventory values come from existing arguments。
- `CompletedAt = time.Now().UTC().Format(time.RFC3339Nano)`。
- `Error = cause.Error()` only when cause is non-nil。

Required tests in `engine/engine_test.go`:

- [ ] Existing legacy marker tests continue unchanged and pass。
- [ ] Structured max-cycles marker is valid JSON and has exact binding。
- [ ] Structured reduce-only marker is valid JSON and safe reason。
- [ ] Structured risk-halt marker is critical and does not request auto-stop merely because marker exists。
- [ ] Structured max-cycle-drain-failed marker is critical and preserves error stop behavior。
- [ ] Pre-existing critical marker cannot be downgraded by later safe completion。
- [ ] Binding mismatch/corrupt marker causes marker write error and preserves fail-closed stop behavior where the existing caller already stops on marker failure。

Run focused tests:

```bash
go test ./engine -run 'Test.*(DoneMarker|RiskHalt|MaxCyclesDrainFailed)' -count=1
go test ./cmd/quant -run 'TestPrepareRunContract' -count=1
```

Commit:

```bash
git add cmd/quant/main.go cmd/quant/main_test.go \
  engine/engine.go engine/engine_test.go
git commit -m "feat: emit bound trading run manifests and markers"
git fetch origin
git rebase origin/master
```

### Task 5: Operator documentation

Create `docs/trading-run-contract.md` with:

- Exact env variables/state layout/schema/reason table from section 4。
- Statement that human TQ foreground mode is canonical and watchdog is legacy/non-SkyEye mode。
- Inspection commands using `jq` or `python -m json.tool` only as optional operator tools, not runtime dependencies。
- Manual archive procedure that uses `mkdir` + `mv`, never deletion。
- Different handling for safe, critical and incomplete runs。
- Recovery rule: verify process/exchange inventory before archiving critical/incomplete state。

Update `docs/trading-server-runbook.md` and `docs/max-cycles-flat-to-flat-drain-design.md` so they do not claim every marker is legacy key/value. Update `docs/project-brief.md` and prepend `docs/work-log.md` using project format.

Commit:

```bash
git add docs/trading-run-contract.md docs/trading-server-runbook.md \
  docs/max-cycles-flat-to-flat-drain-design.md docs/project-brief.md docs/work-log.md
git commit -m "docs: document trading run monitoring contract"
git fetch origin
git rebase origin/master
```

## 7. Required Verification

Run all commands from the dedicated worktree. No live command is authorized.

```bash
bash -n scripts/tq
bash scripts/tq_test.sh
bash scripts/watchdog_test.sh
test -z "$(gofmt -l internal/runstate cmd/quant engine)"
go test ./internal/runstate -count=10
go test ./cmd/quant -run 'TestPrepareRunContract' -count=10
go test ./engine -run 'Test.*(DoneMarker|RiskHalt|MaxCyclesDrainFailed)' -count=10
go test ./... -count=1
go test -race ./internal/runstate ./cmd/quant ./engine -count=1
go vet ./...
go build ./...
git diff --check origin/master..HEAD
git status --short --branch
```

Run `gofmt -w` only on Go files changed by this branch before the formatting check; do not mechanically rewrite unrelated files。

Secret and scope checks:

```bash
git diff --name-only origin/master..HEAD
git diff -U0 origin/master..HEAD | \
  rg '^\+.*(TOOBIT_API_(KEY|SECRET)|SIDECAR_AUTH_TOKEN|CF_ACCESS_CLIENT_SECRET)=' || true
```

The final response must report each command and actual pass/fail result. Do not claim full verification if race/full-suite/build were not run.

## 8. Acceptance Criteria

1. After the one-time untracked `.env` addition `TQ_STRATEGY=mexc-toobit-btc`, user still launches with exactly `scripts/tq live run --human <config>`。
2. No PID file is introduced; manifest PID is written by actual quant process。
3. Manifest appears before any executor/exchange I/O and contains full canonical binding。
4. Raw log path and run ID match the TQ-created file exactly。
5. Safe completion has a matching JSON marker and is distinguishable from critical safety state。
6. `risk_halt` remains critical even when process stays alive。
7. Existing critical marker cannot be overwritten by a later safe reason。
8. Stale/different-run/corrupt marker cannot suppress an alert by pretending to be current。
9. A second human launcher is refused while current state/lock exists。
10. Direct quant and watchdog legacy behavior/tests remain compatible。
11. No trading logic, PNL formula, logging format or dependencies change。
12. The two JSON fixtures parse and match the Go schema exactly。
13. No live process, sidecar, exchange or credential was touched during implementation/testing。

## 9. Delivery Back to SkyEye

After implementation, send the SkyEye agent:

- Branch name and final commit SHA。
- Exact base `origin/master` SHA。
- `docs/contracts/fixtures/run-manifest.v1.json`。
- `docs/contracts/fixtures/done-marker.v1.json`。
- Full verification summary。
- Any deviation from this schema; deviations require SkyEye owner approval before merge。

Do not push or open a PR unless the owner explicitly requests publishing. Keep the worktree available for cross-repo integration review.
