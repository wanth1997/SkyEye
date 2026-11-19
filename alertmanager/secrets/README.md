# alertmanager/secrets/

這個目錄內容**不進 git**（被 `.gitignore` 排除）。

Alertmanager 啟動時讀取這裡的檔案作為 credential。

## 需要放的檔案

| 檔名 | 內容 | 建立時機 |
|---|---|---|
| `tg_token` | Telegram bot token（一整串，無換行） | Phase 0-A |
| `smtp_password` | SMTP 密碼或 API key | 填 SMTP 值時，見下方 |
| `email-addresses.tmpl` | High 告警 email 的收件者與寄件者 | 填 SMTP 值時，見下方 |
| `deadman_url` | 外部 heartbeat 服務的 ping URL（一行） | `SkyEyeWatchdog` 部署、且 Alertmanager ≥ v0.28.0 之後，見下方 |

`smtp_password` 和 `email-addresses.tmpl` 要等 email route 那次部署完成後才能放，否則舊版 `scripts/central-deploy` 會拒絕部署。完整順序見 [`runbooks/trading-alert-promotion.md`](../../runbooks/trading-alert-promotion.md)。

**`deadman_url` 只能在執行中的 Alertmanager ≥ v0.28.0 時放。** 先跑 `sudo docker compose exec -T alertmanager alertmanager --version`，低於 0.28.0 就停止。在 v0.27.0 上，`url_file` webhook 收到 ping 端點的非 2xx 回應（例如 404、503）會 nil pointer panic，整個 Alertmanager 退出，Telegram 與 email 一起停；上游修正是 [prometheus/alertmanager#3800](https://github.com/prometheus/alertmanager/pull/3800)，收錄於 v0.28.0。Repo 現在釘 v0.34.2，production 照 [`runbooks/alertmanager-upgrade.md`](../../runbooks/alertmanager-upgrade.md) 升級後才會通過這個檢查。

它也要等 `SkyEyeWatchdog` 那次部署完成後才能放。檔案還不存在時，Alertmanager 照常運作，只有 dead man's switch 的 ping 每分鐘失敗一次，不發 HTTP 請求、不會送出任何東西；放好後下一分鐘就開始 ping，不用 reload。放法、權限與驗證見 [`runbooks/skyeye-watchdog.md`](../../runbooks/skyeye-watchdog.md#4-放-secret)。

`email-addresses.tmpl` 語法壞掉時，Alertmanager reload 會被拒，重啟也起不來，Telegram 會一起停。放好後一定要先在 container 內跑 `amtool check-config`，通過才 reload。

## 安全守則

- **目錄權限 `2750`（setgid）、group `65534`（host 上的 `nogroup`）；secret 檔案權限 `0640`、owner `ubuntu`、group `65534`**
  - Alertmanager container 內部以 `nobody`（uid/gid 65534）執行；如果把 secret 設成 `0600`，`nobody` 會讀不到 `ubuntu`（uid 1000）所有的檔案，導致 Telegram 告警靜默中斷
  - 目錄加上 setgid（`2750`）並將群組設為 `65534` 後，在這個目錄內新建的檔案會自動繼承 group `65534`；搭配 `0640` 即可讓 container 內的 `nobody` 讀取，同時禁止其他無關本機使用者讀取（若從其他目錄 `mv` 進來不會繼承群組，要另跑 `sudo chgrp 65534`）
  - **注意 `>` 覆寫既有檔案會保留原檔案的群組**，不會套用目錄的 setgid；因此輪替任何既有 secret 前，都必須先完成下方的一次性初始化，否則從舊權限模型留下的檔案在 `chmod 640` 後會讓 `nobody` 讀不到
  - `alertmanager/secrets/README.md` 本身受 git 追蹤、不是 secret，豁免於這條規則
  - Secrets 仍受保護：`.gitignore`（不進 git）、EBS 加密（at-rest）、container 掛 `:ro`（不可寫）
- **不要** `cat` 出內容；也**不要**貼到任何對話 / ticket / log
- 主備份：用 1Password / Bitwarden 存一份副本，機器掛了才有救
- 輪替：每 180 天換一次（Telegram `/revoke` 重新拿 token）

### 一次性初始化（全新 clone 或從舊權限遷移）

`ubuntu` 不是群組 `65534`（`nogroup`）的成員，直接以 `ubuntu` 執行 `chmod 2750` 雖會回傳 0，但 Linux 會靜默丟掉 setgid 位元；因此目錄權限必須先 `sudo chgrp 65534`，再用 `sudo chmod 2750`，並用 `stat` 確認輸出。

既有主機同時要把已存在的 secret 檔（`tg_token`、`smtp_password`、`email-addresses.tmpl`、`deadman_url`；略過尚未建立的檔案與受 git 追蹤的 `README.md`）逐檔轉成 group `65534` 與 `0640`，並從 container 內驗證可讀：

```bash
cd /home/ubuntu/SkyEye

sudo chgrp 65534 alertmanager/secrets
sudo chmod 2750 alertmanager/secrets
stat -c '%a %g' alertmanager/secrets   # 必須印出：2750 65534

for f in tg_token smtp_password email-addresses.tmpl deadman_url; do
  [ -f "alertmanager/secrets/$f" ] || continue
  sudo chgrp 65534 "alertmanager/secrets/$f" && chmod 640 "alertmanager/secrets/$f"
  sudo docker compose exec -T alertmanager test -r "/etc/alertmanager/secrets/$f" && echo "$f: readable"
done
```

## 寫入 token 的安全方法

絕對不要用 `echo "TOKEN" > tg_token`（會留在 shell history）。先完成上方一次性初始化（`>` 覆寫既有檔案會保留原群組，因此只有在既有的 `tg_token` 已轉為 group `65534`、且目錄為 `2750 65534` 之後，輪替才是安全的），再改用：

```bash
# 讀入時不回顯、不留歷史
read -rs TG
# 貼上 token 後按 Enter（看不到字）

printf '%s' "$TG" > /home/ubuntu/SkyEye/alertmanager/secrets/tg_token
unset TG
chmod 640 /home/ubuntu/SkyEye/alertmanager/secrets/tg_token

# 驗證（只看長度、不印內容）
wc -c < /home/ubuntu/SkyEye/alertmanager/secrets/tg_token
# 正常長度約 46 字元
```

### 任何 secret 變更後的必跑驗證

每次新增、修改或調整 `alertmanager/secrets/` 下的 secret 檔案後，都要從 container 內確認 `nobody` 可讀：

```bash
cd /home/ubuntu/SkyEye
sudo docker compose exec -T alertmanager test -r /etc/alertmanager/secrets/<file> && echo readable
```
