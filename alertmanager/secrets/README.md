# alertmanager/secrets/

這個目錄內容**不進 git**（被 `.gitignore` 排除）。

Alertmanager 會在啟動時讀取這裡的檔案作為 credential。

## 需要放的檔案

| 檔名 | 內容 | 建立時機 |
|---|---|---|
| `tg_token` | Telegram bot token（一整串，無換行） | Phase 0-A |
| `smtp_pass` | Gmail App Password（16 字） | Phase 0-B |

## 安全守則

- **檔案權限 `0644`，目錄權限 `0755`**
  - 為什麼不是 0600/0700：Alertmanager container 內部以 `nobody` (uid 65534) 執行，無法讀取 ubuntu (uid 1000) 所有的 0600 檔案
  - 這台單人 EC2 上只有 ubuntu + root，「world-readable」實際風險是零
  - Secrets 仍受保護：`.gitignore`（不進 git）、EBS 加密（at-rest）、container 掛 `:ro`（不可寫）
- **不要** `cat` 出內容；也**不要**貼到任何對話 / ticket / log
- 主備份：用 1Password / Bitwarden 存一份副本，機器掛了才有救
- 輪替：每 180 天換一次（Telegram `/revoke` + Gmail App Password 重生）

## 寫入 token 的安全方法

絕對不要用 `echo "TOKEN" > tg_token`（會留在 shell history）。改用：

```bash
# 讀入時不回顯、不留歷史
read -rs TG
# 貼上 token 後按 Enter（看不到字）

printf '%s' "$TG" > /home/ubuntu/SkyEye/alertmanager/secrets/tg_token
unset TG
chmod 644 /home/ubuntu/SkyEye/alertmanager/secrets/tg_token

# 驗證（只看長度、不印內容）
wc -c < /home/ubuntu/SkyEye/alertmanager/secrets/tg_token
# 正常長度約 46 字元
```

SMTP password 同樣方式寫入 `smtp_pass`。
