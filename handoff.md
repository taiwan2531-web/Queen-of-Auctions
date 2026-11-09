# 交接檔（handoff.md）

> 任何 Agent、任何電腦接手前**必讀**；收工時**必更新**。本檔只放交接必需的精簡資訊，詳細脈絡放 `obsidian/工作記錄.md`。

## ⏯️ 目前做到哪

2026-11-09 把「13 天無聲空轉」這件事從頭查到尾，補完上架並修掉三個病根。

**事故經過**：10/26 清除 61 筆時，`w629/index.html` 的導覽修補沒進 commit，
工作區從此一直不乾淨，10/28、10/31、11/4、11/7 **四次排程全部在第 0 步 exit 3**，
13 天沒有任何上架，而且完全無聲——只有人主動來問才會發現。

**這一輪做完的事**：
- 補上積了 15 天的量：新增 **98 筆**（w1091–w1188）、就地更新 120 筆、清除 76 筆
- 語音 218 筆全數生成（本機 GPU，平均 32 秒/筆）
- 關掉 `core.fsmonitor`／`core.untrackedCache`（見下方「四次漏檔的真正原因」）
- 產線加上**單一實例互斥鎖**、git stderr 寫進 log、自我修復改用白名單路徑
- `purge_expired.py` 的核對改成**不信任 `git status`**
- 雲端語音 workflow 改為只能手動觸發

## 🚦 目前狀態

- **可運行**。線上 **548 筆**，`index.html`／`voice.mp3`／`card.jpg`／`hero.jpg`／BASE_ITEMS **五項都是 548**。
- 工作區乾淨，與 `origin/main` 同步。沒有做一半的東西。
- 下次排程 **2026-11-11（三）09:07**。

## 🔴 四次漏檔的真正原因：fsmonitor，不是「Google Drive 延遲」

先前四次事故（8/28、10/13、10/26、11/9）我一路歸因為「repo 在 Google Drive 上，
剛寫入的檔案 git 看不到」。**這個說法指不出任何官方依據，而且解釋不了關鍵事實**：

🔴 **10/26 那次，purge 的核對機制其實已經存在**（`a6cc07b` 00:05:26，比清除 commit
`a45264d` 00:08:38 早三分鐘），核對條件包含「`git status --porcelain` 為空」，
卻仍然放行了——**因為 `git status` 回報工作區乾淨，而磁碟上的 `w629/index.html`
跟 HEAD 其實不一樣**。核對邏輯沒錯，錯在它建立在一個會說謊的指令上。

查到的事實（2026-11-09 實測）：

| 項目 | 實測值 |
|------|--------|
| `core.fsmonitor` | `true`，且 `git fsmonitor--daemon status` 回報**正在監看本 repo** |
| `core.untrackedCache` | `true` |
| `fsmonitor.allowRemote` | 未設定 |
| G: 的檔案系統 | 回報 `FAT32`、`DriveType=3`，但 `Get-Volume` 讀不到——Google Drive 的虛擬檔案系統 |
| git 版本 | 2.55.0.windows.3 |

fsmonitor daemon 靠檔案系統變更通知決定「哪些檔案需要重新檢查」。虛擬檔案系統
不保證把通知送齊，git 就會信任快取而回報「沒變」。`untrackedCache` 靠目錄 mtime，
在這種檔案系統上同樣不可靠。

**已處置**：兩個設定都 `--unset`，daemon 已停止監看。
代價實測：`git status` 由近乎零變成 **0.3～1.3 秒**，對一條跑兩小時的產線可忽略。

⚠️ **這仍是推論，不是證實的因果。** 我沒有做出「開著 fsmonitor 就漏、關掉就不漏」
的對照實驗（事故要等排程自然發生）。但關掉的代價是一秒，且隨時可還原：

```powershell
git config core.fsmonitor true ; git config core.untrackedCache true
```

**接下來幾次排程要盯的就是這件事**：若關掉後不再出現「commit 漏檔」，推論成立；
若還是漏，`fsmonitor` 不是（唯一）原因，要回頭查 Google Drive 本身。

## 🔴 併發：2026-11-09 連發兩次

同一天兩次失敗，形狀完全一樣——**同一份工作有兩個生產者，沒有互斥**：

| 時間 | 兩個生產者 | 後果 |
|------|-----------|------|
| 23:49 與 00:02 | 兩個 `run_pipeline.ps1` 實例 | 同時寫檔，後者第 8 步 `git add` 回 **exit 128** |
| 02:27–06:46 | 本機 GPU 批次 ＋ 雲端 Actions | 同一批 14 筆 `voice.mp3` 各生成一次，**14 個二進位檔衝突**要人工收 |

**已處置**：
- `run_pipeline.ps1` 加具名 Mutex（`Global\QueenOfAuctions-Pipeline`），重複執行回 **exit 6**。
  用 Mutex 而不是鎖檔：鎖由 OS 持有，程序被砍或當掉自動釋放，
  **不會留下要人工清的卡死鎖**（已實測：持有中拒絕、持有者未釋放就結束後下一個拿得到）。
- 雲端 `Generate Clone Voice` 移除 `on: push`，只剩 `workflow_dispatch` 手動觸發。
  雲端保留作「新電腦沒有 NVIDIA 顯卡」時的後路——它是 CPU，一筆約 20 分鐘。

## 🤖 自動上架

**Windows 工作排程器 `QueenOfAuctions-Publish`｜每週三、六 09:07**
→ `C:\Users\ken\Scripts\QueenOfAuctions\launch_pipeline.ps1`（C:，本機）
→ `run_pipeline.ps1`（G:，repo 內）

- 只在**你登入時**執行；09:07 沒登入的話，登入後補跑
- 護欄：爬蟲 < 800、新物件 > 200、更新 > 200、單次清除 > 300，任一觸發就中止不推
- 工作區不乾淨時**只自動收拾產線產物**（已追蹤的 `104woo.html`／`wNNN/index.html` 被修改），
  其餘一律停下來等人
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
| 6 | 已有另一個實例在跑，本次略過（2026-11-09 新增） |

紀錄：產線 `output\pipeline-logs\<時間戳>.log`／`.stats.json`；啟動器 `%LOCALAPPDATA%\QueenOfAuctions\launcher-logs\`。
失敗時啟動器會跳 Windows 通知並寫 `%LOCALAPPDATA%\QueenOfAuctions\LAST-RESULT.txt`。
log 裡的中文會疊字（「爬爬蟲蟲」），是轉譯的編碼疊加，**判斷以 `stats.json` 為準**。

手動跑：`powershell -ExecutionPolicy Bypass -File run_pipeline.ps1`（`-DryRun` 只看統計、`-SkipCrawl` 沿用最新爬蟲檔、`-NoPush` 只 commit）。
你在場時也可以說「爬蟲上架」，走 skill `auction-publish`。

### 排程紀錄

| 日期 | 結果 | 內容 |
|------|------|------|
| 9/23～10/26 | 正常 | 期間多次上架與清除，詳見 git log |
| 10/26 | 成功 | 清除 61 筆，但 `w629/index.html` 漏進 commit → 埋下後面 13 天的空轉 |
| 10/28 | exit 3 | 工作區不乾淨（w629） |
| 10/31 | exit 3 | 同上 |
| 11/4 | exit 3 | 同上 |
| 11/7 | exit 3 | 同上。**13 天、四次，全程無聲** |
| 11/8 23:49（手動） | 中止 | 被 11/9 00:02 那次的併發波及，停在第 3 步 |
| 11/9 00:02（手動） | exit 2 | 步驟 3～7 完成，第 8 步 `git add` exit 128（併發）→ 人工補完 |
| 11/9（人工收尾） | 成功 | 新增 98、更新 120、語音 218、清除 76 |

## ➡️ 下一步

1. **11/11（三）09:07 是所有修改後的第一次排程**，跑完查 `LastTaskResult`，應為 0。
   這一次同時在驗三件事：fsmonitor 關閉後還會不會漏檔、互斥鎖會不會誤擋、補推邏輯正常。
2. **六項審查發現已全部處置**（見下節），但 **AGY（Antigravity）至今沒有收到審查**。
   指示在 `output\20261109_產線自癒與通知_審查指示.md`，**要人工貼給它**（本機 Antigravity 無 CLI，Claude Code 叫不動）。
   ⚠️ 該指示本身有三處錯誤已知待改，見下節最後一項。
3. **自我修復機制要不要留著**，等 11/11 與 11/14 兩次排程的結果再決定。
   它是為了補「Google Drive 延遲」而加的；若根因其實是 fsmonitor，它就是在補一個不該存在的問題，
   而它的代價已經實證過：11/8 測試時它**把人手加的測試標記自動 commit** 進 `7e5713e`。
4. （可選）架構候選 B：頁面模板單一真理源，見 `agents.md` 路線圖。

## 🔍 2026-11-09 審查發現的處置

獨立審查員提了六項，**六項我都唯讀查證屬實**，處置如下：

| # | 發現 | 處置 |
|---|------|------|
| 1 | `core.fsmonitor`／`untrackedCache` 開著，在虛擬檔案系統上不可靠 | ✅ 兩個都 unset，daemon 已停 |
| 2 | 自我修復判斷只看白名單，卻用 `git add -A` 收整個工作區 | ✅ 改成只 add 逐筆檢查過的路徑 |
| 3 | 測試標記被自動 commit 進 `7e5713e`（未推送） | ✅ 已移除。`reset` 被 deny 清單擋下（刻意的保險），改用前推修正 `4f04d49` |
| 4 | purge 的 `git commit --amend` 可能改寫已推送的 commit | ✅ 改成只有「本次確實建立了 commit」才 amend，否則另開新 commit |
| 5 | purge 核對只驗 BASE_ITEMS 筆數與 `git status` | ✅ 改用 `git hash-object` 逐檔比對磁碟與 HEAD 的 blob oid（不經 index／fsmonitor），再加「BASE_ITEMS ⇔ 資料夾一一對應」與「導覽無壞連結」兩道純磁碟檢查。實測 548 檔 4.2 秒、零誤報、弄髒抓得到 |
| 6 | 「無異動」與 `-DryRun` 兩條 `exit 0` 路徑不推送，自我修復的 commit 會永遠留在本機 | ✅ 兩處加 `Push-Pending`，收尾也加一次 |

另外審查員指出我寫的審查指示本身有三處錯誤，**尚未修正**：
- `0x8007010B` 是 `ERROR_DIRECTORY`（工作目錄無效），我先前歸因「第三方防毒擋 AppData」**沒有證據**
- 「Google Drive 寫入後對 git 不可見」查不到官方依據（見上方 fsmonitor 一節）
- 另一項待覆核

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

爬蟲用 `.venvs\fapai104`、語音用 `.venvs\voxcpm`。語音約 32 秒/筆。

## ⚠️ 注意事項

- 🔴 **不要再開第二個產線實例。** 現在有 Mutex 會回 exit 6 擋下，但語音批次（`local_voice_batch.py`）
  **沒有鎖**，手動跑之前先確認沒有別的在跑：
  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Select ProcessId, CommandLine
  ```
- 🔴 **核對 commit 不要用 `git status`。** 10/26 就是被它騙過去的。
  要驗「磁碟內容是否真的進了 commit」，用 `git hash-object` 跟 `git ls-tree -r HEAD` 比 oid
  （`purge_expired.py` 的 `differs_from_head()` 是現成的寫法）。
- **改了 repo 裡的 `launch_pipeline.ps1`，要重新複製到 `C:\Users\ken\Scripts\QueenOfAuctions\`**，排程跑的是 C: 上的複本。
- 🔴 **啟動器不能放 `%LOCALAPPDATA%`**。2026-09-19 排程失敗（`0x8007010B` = `ERROR_DIRECTORY`，
  工作目錄設別處則 `0xFFFD0000`），兩種都**完全沒執行、沒有任何 log**。
  搬到 `C:\Users\ken\Scripts\` 後實測正常。成因未確認——先前「第三方防毒」的說法沒有證據，不要當結論引用。
- **`publish_new.py` 不在本 repo**，在 `G:\我的雲端硬碟\ai agent\法拍 104\`，
  其 `REPO` 常數**寫死指向本資料夾**。搬動或改名本資料夾時必須同步修改。
- **保留期與就地更新必須成套**。若把保留期改回 7 天又用 `--no-update`，
  還在拍的物件會被當重複跳過、停在過期拍別而被隱藏，**從網站上消失**。
- **爬蟲偶爾不給照片也不給座標**（w717、w877、w878）。上架當下會缺底圖，
  後續排程若爬到資料會自動補齊；若一直沒有，完整性檢查會持續 exit 2。
- **每批爬蟲都會有「嘉市」標籤錯置**，`fix_city_labels.py` 必跑，且**必須早於語音**。
- **爬蟲的開標時間常是 `..` 之類的雜訊**。就地更新已處理，但**新增物件路徑仍原樣寫入**。
- **專案 `.claude/settings.json` 的 deny 清單擋了 `Remove-Item`／`rm`／`git clean`／破壞性 git**，
  Claude Code 在本專案要刪檔或改寫歷史會被拒，這是刻意的保險。11/9 就擋下了一次 `git reset`。
- **只能有一份 clone**。2026-08-22 前有兩份，其中一份落後 61 個 commit 沒人發現。
- 驗證 tinyurl 時，**別用 Python 在 Windows 寫出的清單直接餵 curl**——
  預設換行是 `\r\n`，尾端的 `\r` 會讓每一筆請求失敗（開檔指定 `newline='\n'` 或 `tr -d '\r'`）。
- **Bash 工具的 heredoc 會把 `\\` 折成 `\`**，Python 的 `\d`、`\n`、`\U` 會被弄壞。
  要寫含反斜線的腳本，用 Write 工具寫檔，不要用 heredoc。

## 🕐 最後更新

- 時間：2026-11-09 12:30
- 更新者：Claude Code (Opus 5) @ KEN-PC
- Git push：待本次 commit
