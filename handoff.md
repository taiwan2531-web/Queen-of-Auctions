# 交接檔（handoff.md）

> 任何 Agent、任何電腦接手前**必讀**；收工時**必更新**。本檔只放交接必需的精簡資訊，詳細脈絡放 `obsidian/工作記錄.md`。

## ⏯️ 目前做到哪

2026-09-17 修好排程的「假成功」與破圖問題，並經由新啟動器實跑一次驗證：
- **啟動器** `launch_pipeline.ps1`：排程改呼叫 C: 上的複本，先等 G: 就緒、跑完確認有 log
- **補齊缺漏**：`publish_new.py` 就地更新時補上上架當下缺的照片與座標。
  這次補了 10 筆——w877、w878 補照片與座標（原本線上破圖），另 8 筆補座標（生活機能原本是預設文字）
- 回報用的 Claude Code 排程已刪除（三次都 5 秒就結束，無作用）
- 自動 commit 標題的 BOM 已修

## 🚦 目前狀態

- **可運行**。線上 526 筆 = 本地 526 筆，`index.html`／`voice.mp3`／`card.jpg`／`hero.jpg` 缺 0。
- **在架 272 筆**（其餘已過開標時刻，被 `delist.js` 隱藏，屬正常）。
- 工作區乾淨，與 `origin/main` 同步。沒有做一半的東西。

## 🤖 自動上架

**Windows 工作排程器 `QueenOfAuctions-Publish`｜每週三、六 09:07**
→ `C:\Users\ken\Scripts\QueenOfAuctions\launch_pipeline.ps1`（C:，本機）
→ `run_pipeline.ps1`（G:，repo 內）

- 只在**你登入時**執行；09:07 沒登入的話，登入後補跑
- 護欄：爬蟲 < 800、新物件 > 200、更新 > 200，任一觸發就中止不推
- 工作區不乾淨直接中止，**不會自行 commit 或丟棄你做到一半的東西**
- 最後檢查每個物件的四個檔案都在，缺一個就算失敗

查結果：

```powershell
Get-ScheduledTaskInfo -TaskName 'QueenOfAuctions-Publish' | Select NextRunTime, LastRunTime, LastTaskResult
```

| LastTaskResult | 意思 |
|:--:|------|
| 0 | 成功或無異動 |
| 1 | 護欄觸發 |
| 2 | 執行失敗（含完整性檢查缺件） |
| 3 | 工作區不乾淨 |
| 4 | 產線回報成功卻沒有 log——假成功 |
| 5 | 等了 20 分鐘仍讀不到 G: 上的腳本 |

紀錄：產線 `output\pipeline-logs\<時間戳>.log`／`.stats.json`；啟動器 `%LOCALAPPDATA%\QueenOfAuctions\launcher-logs\`。
log 裡的中文會疊字（「爬爬蟲蟲」），是轉譯的編碼疊加，**判斷以 `stats.json` 為準**。

手動跑：`powershell -ExecutionPolicy Bypass -File run_pipeline.ps1`（`-DryRun` 只看統計、`-SkipCrawl` 沿用最新爬蟲檔、`-NoPush` 只 commit）。
你在場時也可以說「爬蟲上架」，走 skill `auction-publish`。

### 排程紀錄

| 日期 | 結果 | 內容 |
|------|------|------|
| 9/6（手動） | 成功 | 新增 50（w823–w872）、更新 68 |
| 9/9 | exit 2 | 新增 13（w873–w885）、更新 29；w877／w878 缺圖導致完整性檢查失敗 |
| 9/12 | exit 2 | 新增 22（w886–w907）、更新 36；同上 |
| 9/16 | **假成功** | 回報 0，實際沒跑（登入 5 分鐘後補跑，G: 未就緒）→ 促成啟動器 |
| 9/17（手動，經啟動器） | 成功 | 補齊 10 筆，tinyurl 10/10 |
| 9/19 | **啟動失敗** | `0x8007010B`；啟動器裝在 `%LOCALAPPDATA%`，排程執行不了，沒有 log |

## ➡️ 下一步

1. **9/23（三）09:07** 是啟動器搬到 `C:\Users\ken\Scripts\` 後第一次由排程觸發，
   跑完查 `LastTaskResult`，應為 0（9/19 那次因為裝在 AppData 而啟動失敗，已修）。
2. **9/12 之後沒有再跑過爬蟲**（9/16 假成功、9/19 啟動失敗），到 9/20 已隔 8 天。
   要補跑：`powershell -ExecutionPolicy Bypass -File run_pipeline.ps1`，或等 9/23 排程。
3. **清除過期物件**：`python purge_expired.py --dry-run` → 確認後 `--push`。
   9/17 01:21 跑過是 0 筆，`w433` 已於 9/17 稍晚到期。**排程不會自動清除**，要人確認。
4. （可選）架構候選 B：頁面模板單一真理源，見 `agents.md` 路線圖。

## 💻 換電腦？

看 [docs/新電腦設定.md](docs/新電腦設定.md)。全域設定走 `法拍 104` repo 的 `backup_agent_config.ps1 -Restore`；
排程與 C: 上的啟動器**不隨還原帶過去**，要照文件第 5 步重建。

## 🛠️ 產線指令（手動時照這個順序，不要跳）

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

爬蟲用 `.venvs\fapai104`、語音用 `.venvs\voxcpm`。語音約 28～30 秒/筆。

## ⚠️ 注意事項

- **改了 repo 裡的 `launch_pipeline.ps1`，要重新複製到 `C:\Users\ken\Scripts\QueenOfAuctions\`**，排程跑的是 C: 上的複本。
- 🔴 **啟動器不能放 `%LOCALAPPDATA%`**。2026-09-19 排程失敗（`0x8007010B`）就是這個原因——
  工作排程器執行不了 AppData 底下的腳本，完全不會留下 log。搬到 `C:\Users\ken\Scripts\` 後實測正常。
  （啟動器的 log 仍寫在 `%LOCALAPPDATA%\QueenOfAuctions\launcher-logs`，寫檔沒問題，不能執行的只有腳本。）
- **`publish_new.py` 不在本 repo**，在 `G:\我的雲端硬碟\ai agent\法拍 104\`，
  其 `REPO` 常數**寫死指向本資料夾**。搬動或改名本資料夾時必須同步修改。
- **保留期與就地更新必須成套**。若把保留期改回 7 天又用 `--no-update`，
  還在拍的物件會被當重複跳過、停在過期拍別而被隱藏，**從網站上消失**。
- **爬蟲偶爾不給照片也不給座標**（w717、w877、w878）。上架當下會缺底圖，
  現在後續排程若爬到資料會自動補齊；若一直沒有，完整性檢查會持續 exit 2。
- **每批爬蟲都會有「嘉市」標籤錯置**，`fix_city_labels.py` 必跑。
- **爬蟲的開標時間常是 `..` 之類的雜訊**。就地更新已處理，但**新增物件路徑仍原樣寫入**。
- **專案 `.claude/settings.json` 的 deny 清單擋了 `Remove-Item`／`rm`／破壞性 git**，
  Claude Code 在本專案要刪檔會被拒，這是刻意的保險。
- **只能有一份 clone**。2026-08-22 前有兩份，其中一份落後 61 個 commit 沒人發現。
- **在 G: 上「腳本改檔 → 立刻 `git add`」時，不能假設 git 抓得到**（Google Drive 可見性延遲）。
  commit 後用 `git show --stat HEAD` 核對檔案數。
- 驗證 tinyurl 時，**別用 Python 在 Windows 寫出的清單直接餵 curl**——
  預設換行是 `\r\n`，尾端的 `\r` 會讓每一筆請求失敗（開檔指定 `newline='\n'` 或 `tr -d '\r'`）。

## 🕐 最後更新

- 時間：2026-09-20 08:15
- 更新者：Claude Code (Opus 5) @ KEN-PC
- Git push：✅ 已推
