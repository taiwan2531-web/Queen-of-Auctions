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

## 🤖 上架已排程自動執行（2026-09-05 起改用腳本）

**Windows 工作排程器 `QueenOfAuctions-Publish`｜每週三、六 09:07｜跑 `run_pipeline.ps1`**

- 護欄：爬蟲 < 800、新物件 > 200、更新 > 200，任一觸發就中止不推
- 工作區不乾淨直接中止（exit 3），**不會自行 commit 或丟棄你做到一半的東西**
- 實際筆數與 dry-run 不符也中止
- 退出碼：0 成功或無異動｜1 護欄觸發｜2 執行失敗｜3 工作區不乾淨
- log 在 `output\pipeline-logs\<時間戳>.log`（gitignore，不進版控）
- 手動跑：`powershell -ExecutionPolicy Bypass -File run_pipeline.ps1`
  加 `-DryRun` 只看統計不寫入、`-SkipCrawl` 沿用最新爬蟲檔（省 25 分）、`-NoPush` 只 commit

> **為什麼不用 Claude Code 排程**：2026-08-29、09-02、09-05 連續三次都在第 3 個指令
> `git pull` 就停住，13 秒內結束、什麼都沒做——每個會寫入或連外的指令都會攔一次權限
> 確認，排程執行時沒有人可以按。加 `permissions.allow` 沒解決（指令是
> `cd "..." && git pull ...` 這種複合形狀，前綴比對打不中）。
> 這條產線每一步都是固定順序與參數、護欄是三個數字比較，**根本不需要 LLM**。

skill `auction-publish` 仍在，但改成**手動路徑**——你在場說「爬蟲上架」時用。

## ➡️ 下一步

1. **2026-09-17（含）以後**跑 `python purge_expired.py --dry-run` → 確認後 `--push`。
   今天（8/28）跑過是 0 筆；30 天保留期下**最早到期的是 `w433`，日期 2026-09-17**。
   之後陸續到期：9 月 95 筆、10 月 273 筆、11 月 35 筆。
   **這一項排程不會自動做**——排程只回報，刪除要人確認。
2. 上架已交給排程（見上）。**下次自動執行：2026-08-29（六）09:07**。
   第一次跑完要看一下回報是否正常，特別是有沒有卡在工具權限確認。
3. （可選）架構候選 B：頁面模板單一真理源，見 `agents.md` 路線圖。

## 💻 換電腦？

看 [docs/新電腦設定.md](docs/新電腦設定.md)——venv 怎麼建、GPU 要什麼版本的 torch、
哪幾處路徑寫死了。全域設定與排程走 `D:\ganju-erp` 的 `pnpm agent:restore`。

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
- **在 G: 上「腳本改檔 → 立刻 `git add`」時，不能假設 git 抓得到。**
  G: 是 Google Drive 虛擬磁碟，檔案寫入後的可見性偶有延遲——2026-08-28 就發生過
  Python 腳本已改好 4 個檔，緊接著的 `git add -A` 只看到 2 個，commit 靜靜地漏掉另外兩個。
  **commit 後養成用 `git show --stat HEAD` 核對檔案數的習慣**，或改檔與 add 之間隔開一步。
  產線步驟因為有筆數可核對，漏了會發現；純文件編輯沒有那種天然檢核點，特別危險。
- 驗證 tinyurl 時，**別用 Python 在 Windows 寫出的清單直接餵 curl**——
  預設換行是 `\r\n`，尾端的 `\r` 會讓每一筆請求失敗，看起來像連結全壞（8/28 踩過，先 `tr -d '\r'`）。

## 🕐 最後更新

- 時間：2026-09-06 00:15
- 更新者：Claude Code (Opus 5) @ KEN-PC
- Git push：✅ 已推
