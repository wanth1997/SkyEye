# pool-status/secrets/

這個目錄內容**不進 git**（被此目錄的 `.gitignore` 排除，僅保留受 git 追蹤的 `README.md` 與 `.gitignore`）。

`pool-status` exporter 每次對 GitHub API 發送 HTTP 請求前都會從這裡重新讀取憑證檔案，換檔不需要重啟 container。

## 需要放的檔案

| 檔名 | 內容 | 建立時機 |
|---|---|---|
| `github_token` | GitHub fine-grained PAT（一整串，無換行），resource owner `wanwanlabs`，僅選 repository `self-hosted-runner`，Repository permissions 僅需 `Variables: Read-only`（GitHub 必帶 `Metadata: Read-only`） | `pool-status` 首次部署（啟動 container 之前） |

`github_token` 尚未放置、內容為空或權限不可讀時，`pool-status` container 仍會正常啟動並回應 `/metrics`（不對 GitHub 發送請求，持續將 `pool_status_exporter_read_errors_total{reason="token"}` 加一、`pool_status_exporter_read_timestamp_seconds` 停在 `0`）。放好檔案後下一次 30 秒輪詢即會自動生效，不需重啟 container。

## 安全守則

- **目錄權限 `2750`（setgid）、group `65534`（host 上的 `nogroup`）；secret 檔案權限 `0640`、owner `ubuntu`、group `65534`**
  - `pool-status` container 以 `user: "65534:65534"`（`nobody:nogroup`）及 `read_only: true` 執行；如果把 `github_token` 設成 `0600`，`nobody` 會讀不到 `ubuntu`（uid 1000）所有的檔案，導致 `read_errors_total{reason="token"}` 持續增加
  - 目錄加上 setgid（`2750`）並將群組設為 `65534` 後，在這個目錄內新建的檔案會自動繼承 group `65534`；搭配 `0640` 即可讓 container 內的 `nobody` 讀取，同時禁止其他無關本機使用者讀取（若從其他目錄 `mv` 進來不會繼承群組，要另跑 `sudo chgrp 65534`）
  - **注意 `>` 覆寫既有檔案會保留原檔案的群組**，不會套用目錄的 setgid；因此輪替既有 `github_token` 前，目錄與既有檔案都必須已完成下方的一次性初始化
  - `pool-status/secrets/README.md` 與 `pool-status/secrets/.gitignore` 受 git 追蹤、不是 secret，豁免於這條規則
  - Secrets 仍受保護：`.gitignore`（不進 git）、EBS 加密（at-rest）、container 掛 `/run/secrets/pool-status:ro`（唯讀，整個目錄掛載以支援不重啟換檔）
- **不要** `cat` 出內容；也**不要**貼到任何對話 / ticket / log，也不要放進 `.env` 或 compose 環境變數
- 主備份：存一份副本在 1Password / Bitwarden，並記下到期日前 2 週的輪替提醒

### 一次性初始化（全新 clone 或首次部署）

`ubuntu` 不是群組 `65534`（`nogroup`）的成員，直接以 `ubuntu` 執行 `chmod 2750` 雖會回傳 0，但 Linux 會靜默丟掉 setgid 位元；因此目錄權限必須先 `sudo chgrp 65534`，再用 `sudo chmod 2750`，並用 `stat` 確認輸出。

同時把 token 檔案的精確路徑加進本機 checkout 的 `.git/info/exclude`：日後若透過 revert PR 回退 `pool-status`、`pool-status/secrets/.gitignore` 一併被移除時，留在磁碟上的 `github_token` 仍會被 Git 忽略，避免誤加入未追蹤檔案：

```bash
cd /home/ubuntu/SkyEye

sudo chgrp 65534 pool-status/secrets
sudo chmod 2750 pool-status/secrets
stat -c '%a %g' pool-status/secrets   # 必須印出：2750 65534

EXCLUDE_FILE="$(git rev-parse --git-path info/exclude)"
grep -qxF '/pool-status/secrets/github_token' "$EXCLUDE_FILE" 2>/dev/null || \
  printf '\n%s\n' '/pool-status/secrets/github_token' >> "$EXCLUDE_FILE"
```

## 寫入 token 的安全方法

絕對不要用 `echo "TOKEN" > github_token`（會留在 shell history 且暴露在命令列）。先完成上方一次性初始化，再在 subshell 內先 `unset` 專用變數名，用 `read -rs` 讀入並以 shell builtin `printf` 寫入（不影響操作者既有的 `GH_TOKEN`，也不會把憑證 export 給子程序或出現在外部指令的命令列）：

```bash
# 在 subshell 內讀入並寫檔（不回顯、不留歷史、不動既有 GH_TOKEN）
(
  umask 027
  unset SKYEYE_POOL_TOKEN
  read -rs SKYEYE_POOL_TOKEN
  # 貼上 token 後按 Enter（看不到字）
  builtin printf '%s' "$SKYEYE_POOL_TOKEN" > /home/ubuntu/SkyEye/pool-status/secrets/github_token
)
sudo chgrp 65534 /home/ubuntu/SkyEye/pool-status/secrets/github_token
chmod 640 /home/ubuntu/SkyEye/pool-status/secrets/github_token

# 驗證權限與長度（不印內容）
stat -c '%a %U %g' /home/ubuntu/SkyEye/pool-status/secrets/github_token   # 必須印出：640 ubuntu 65534
wc -c < /home/ubuntu/SkyEye/pool-status/secrets/github_token
```

### 任何 secret 變更後的必跑驗證

每次新增、輪替或調整 `pool-status/secrets/github_token` 後，都要從 container 內確認 `nobody`（uid/gid 65534）可讀：

```bash
cd /home/ubuntu/SkyEye
sudo docker compose exec -T pool-status test -r /run/secrets/pool-status/github_token && echo readable
```
