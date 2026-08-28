# 交接檔（handoff.md）

> 任何 Agent、任何電腦接手前**必讀**；收工時**必更新**。本檔只放交接必需的精簡資訊，詳細脈絡放 `obsidian/工作記錄.md`。

## ⏯️ 目前做到哪

2026-08-28 跑完一輪爬蟲上架：**新物件 56 筆（`w767`–`w822`）＋ 就地更新 55 筆**，總覽 385 → **441 筆**。
這是「同案號就地更新」上線後第一次跑**新增＋更新混合情境**，驗收通過：
55 筆更新的 tinyurl **55/55 仍指向原代號、目的地頁面 55/55 回傳 200**。

## 🚦 目前狀態

- **可運行**。線上 441 筆（與本地一致），`index.html`／`voice.mp3`／`card.jpg`／`hero.jpg` 缺 0。
- 目前**在架 352 筆**（其餘 89 筆已過開標時刻，被 `delist.js` 隱藏，屬正常）。
- 工作區乾淨，與 `origin/main` 同步。沒有做一半的東西。

## 🤖 上架已排程自動執行（2026-08-28 起）

**每週三、週六 09:07** 自動跑完整產線並推上線，不需要人介入。

- 產線步驟寫在 skill `auction-publish`（`C:\Users\ken\.claude\skills\auction-publish\SKILL.md`）
- 排程任務 `auction-publish-wed-sat`（`C:\Users\ken\.claude\scheduled-tasks\`）
- **護欄**：爬蟲總筆數 < 800、新物件 > 200、更新 > 200，任一觸發就中止不推，並回報
- 工作區不乾淨時會停下來問人，不會自行 commit 或丟棄你做到一半的東西
- **前提：電腦要開著且 Claude Code 有開**。關著的話會在下次啟動時補跑
- ⚠️ skill 與排程都放在 `C:\Users\ken\.claude\`，**不在任何 repo 裡**，
  換電腦不會跟著走。備份走 `D:\ganju-erp` 的 `pnpm agent:backup`

## ➡️ 下一步

1. **2026-09-17（含）以後**跑 `python purge_expired.py --dry-run` → 確認後 `--push`。
   今天（8/28）跑過是 0 筆；30 天保留期下**最早到期的是 `w433`，日期 2026-09-17**。
   之後陸續到期：9 月 95 筆、10 月 273 筆、11 月 35 筆。
   **這一項排程不會自動做**——排程只回報，刪除要人確認。
2. 上架已交給排程（見上）。**下次自動執行：2026-08-29（六）09:07**。
   第一次跑完要看一下回報是否正常，特別是有沒有卡在工具權限確認。
3. （可選）架構候選 B：頁面模板單一真理源，見 `agents.md` 路線圖。

## 🛠️ 產線指令（照這個順序，不要跳）

```
# 1. 爬蟲（在 G:\我的雲端硬碟\ai agent\法拍 104）
python crawler_104woo_property.py --city 嘉義縣 台南市 高雄市 屏東縣 --sort-date --pending-only --max-pages 20
# 2. 上架（先 --dry-run 看新增/更新各幾筆）
python publish_new.py output/104woo_物件_4縣市_<時間戳>.json --dry-run
python publish_new.py output/104woo_物件_4縣市_<時間戳>.json
# 3~6（在 Queen-of-Auctions）
python fix_city_labels.py          # 必須早於語音，會改講稿
powershell -File burn_price.ps1
powershell -File apply_price_images.ps1
python apply_swipe_nav.py
& "C:\Users\ken\.venvs\voxcpm\Scripts\python.exe" local_voice_batch.py
```

爬蟲用 `.venvs\fapai104`、語音用 `.venvs\voxcpm`。語音約 28 秒/筆。

## ⚠️ 注意事項

- **`publish_new.py` 不在本 repo**，在 `G:\我的雲端硬碟\ai agent\法拍 104\`，
  其 `REPO` 常數**寫死指向本資料夾**。搬動或改名本資料夾時必須同步修改。
- **保留期與就地更新必須成套**。若把保留期改回 7 天又用 `--no-update`，會出現最糟組合：
  舊物件還在（案號比對到）→ 新拍別被當重複跳過 → 物件頁停在過期拍別 → 被 `delist.js` 隱藏
  → **還在拍的物件反而從網站上消失**。
- **每批爬蟲都會有「嘉市」標籤錯置**，`fix_city_labels.py` 必跑（8/28 這批 2 筆：w806、w814）。
- **爬蟲的開標時間常是 `..` 之類的雜訊**。就地更新已處理（能解析才採用，否則清空交給 `delist.js`
  以 17:00 保守起算），但**新增物件路徑仍是原樣寫入**，留意新頁面出現 `..`。
- **`.gitignore` 的 `output/` 已改寫為 `output/*`**。git 不會進入被排除的「目錄」，
  寫成 `output/` 時 `!output/xxx` 例外規則不會生效。
- **只能有一份 clone**。2026-08-22 前有兩份，導致其中一份落後 61 個 commit 沒人發現。
- 驗證 tinyurl 時，**別用 Python 在 Windows 寫出的清單直接餵 curl**——
  預設換行是 `\r\n`，尾端的 `\r` 會讓每一筆請求失敗，看起來像連結全壞（8/28 踩過，先 `tr -d '\r'`）。

## 🕐 最後更新

- 時間：2026-08-28 12:35
- 更新者：Claude Code (Opus 5) @ KEN-PC
- Git push：✅ 已推
