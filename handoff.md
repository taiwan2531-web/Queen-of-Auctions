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

## 🔔 開工第一件事：看上次排程的結果

```powershell
Get-Content 'G:\我的雲端硬碟\ai agent\Queen-of-Auctions\output\pipeline-logs\LAST-RESULT.txt'
```

一行，長這樣：`2026-11-09 20:01:28  OK  exit=0  成功或無異動  20261109_200128.log`
開頭是 **`FAILED`** 就要處理，退出碼對照見下方表格。成功也會寫，所以看到的一定是最新一次。

> 為什麼要多這個檔：失敗通知原本只有一個會消失的氣球提示 ＋ 寫在
> `%LOCALAPPDATA%` 的紀錄，兩個都沒人會去看——**13 天無聲空轉就是這樣沒被發現的**。
> 這份寫在 repo 的 `output/`（已 gitignore，不會弄髒工作區），開工一定會經過。

## 🚦 目前狀態

- **可運行**。線上 **549 筆**，`index.html`／`voice.mp3`／`card.jpg`／`hero.jpg`／BASE_ITEMS **五項都是 549**。
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

### ✅ 2026-11-09 已用對照實驗證實

每組 12 輪 × （60 個已追蹤 + 60 個未追蹤），共 1440 次檢查。
方法：外部程序寫一批檔 → 立刻由另一個 git 程序 `git status`，
重現產線「寫完馬上 `git add`」的情境。

| 檔案系統 | `fsmonitor` 關 | `fsmonitor` 開 |
|----------|---------------|----------------|
| **G:（Google Drive）** | 0 / 1440 漏看 | **720 / 720 已追蹤檔案漏看（100%）** |
| **C:（NTFS）** | 0 / 1440 | **0 / 1440** |

**是 `fsmonitor` × Google Drive 的組合**：git 沒壞（C: 上開關都 0 漏看），
Drive 單獨也沒問題（關掉後 G: 上 0 漏看）。

🔴 **而且只漏「被修改的已追蹤檔案」，未追蹤的新檔案一次都沒漏。**
這與四次事故完全吻合——漏掉的全是 `104woo.html` 與導覽頁（已追蹤被修改），
而每一批新增的 `wNNN/` 資料夾**一次都沒漏過**。

**所以不必把 repo 搬離 Google Drive。** AGY 報告主張「唯一根因是 Drive、
應立即遷至本機 SSD」，但關掉一個設定就能解決，不必付搬遷的代價
（改 `publish_new.py` 寫死的路徑、重建排程、重驗整條產線、失去跨電腦同步）。

**防呆已加**：產線第 0 步會檢查 `core.fsmonitor`，發現被打開就自動關掉再跑
（git 升級、其他工具或手動設定都可能把它打開）。實測有效。

還原方式（**不要這樣做**，留著只是說明怎麼復原）：

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
| 241 | 護欄觸發 |
| 242 | 執行失敗（含完整性檢查缺件） |
| 243 | 工作區不乾淨 |
| 244 | 產線回報成功卻沒有 log——假成功 |
| 245 | 等了 20 分鐘仍讀不到 G: 上的腳本 |
| 246 | 已有另一個實例在跑，本次略過 |

🔴 **2026-11-09 由 1～6 改成 241～246。** 工作排程器的「上次執行結果」會把退出碼
當成 Win32 錯誤碼翻成訊息，`net helpmsg` 實測：

| 舊碼 | 排程器會顯示成 |
|:--:|------|
| 1 | 功能錯誤 |
| 2 | 系統找不到指定的檔案 |
| 3 | **系統找不到指定的路徑** ← 13 天空轉期間就是一直顯示這句 |
| 4 | 系統無法開啟檔案 |
| 5 | **存取被拒** ← 會讓人去查帳號密碼與 ACL |
| 6 | 控制代碼無效 |

241～253 沒有對應的系統訊息，排程器只顯示裸退出碼。
⚠️ 15 與 50 也是 Win32 碼（系統找不到指定的磁碟機／不支援這個要求），不要用。

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
2. **雙 AI 審查已完成**（內部審查員 ＋ AGY／Antigravity 跨廠商）。四份文件收在
   **`obsidian/審查紀錄/`**：審查指示、內部審查報告、AGY 審查報告、**覆核紀錄**。
   > 刻意放 `obsidian/` 不放 `output/`——`output/*` 整個被 gitignore，
   > 只放那裡會隨 Drive 一起消失（`D:\ganju-erp` 就消失過一次，3 個 commit 沒了）。
   > 而且「當初為什麼這樣決定」本來就屬於三處分工裡的 Obsidian。

   🔴 **覆核紀錄第五節有兩處「兩份報告互相矛盾、要你決定」的項目**：
   根因是 Google Drive 還是 fsmonitor（要不要搬 repo）、白名單該更寬還是更嚴。
3. 🔴 **11/11 與 11/14 這兩次排程要盯「自癒有沒有被觸發」**，不是只看退出碼 0。

   使用者 2026-11-09 決定：**repo 暫不搬離 Google Drive**，先用這兩次排程驗
   「關掉 fsmonitor 之後還會不會漏檔」。

   | 觀察到 | 代表 |
   |--------|------|
   | 兩次都沒觸發自癒、退出碼 0 | 與實驗結果一致，收工 |
   | log 出現「全部是產線產物…自動收拾後繼續」 | **仍在漏檔**，實驗沒涵蓋到的成因，要重查 |
   | log 出現「⚠ core.fsmonitor = true」 | 有東西把它打開了，防呆有擋住，但要查是誰開的 |
   | 退出碼 243 | 工作區有自癒收不了的東西，要人看 |

   ⚠️ **自癒被觸發 ≠ 沒問題。** 它是在補漏檔，每觸發一次就是一次漏檔。
4. （可選）架構候選 B：頁面模板單一真理源，見 `agents.md` 路線圖。

## 🔴 案號正規化失效（11/9 由煙霧測試意外發現，已修）

改完產線後跑 `-DryRun -SkipCrawl` 煙霧測試，結果冒出一筆「新物件」。
追下去發現 `canon_case` 有三個 bug，**550 個案號只有 422 個真的被正規化**：

1. 「字」只允許單一個中文字 `([一-鿿])`，但真實的字是多字元：`職亥`、`職酉`、`司執助恭`
2. **不認識金拍字軌**。台灣金服（TFASC）受各地方法院民事執行處囑託辦理不動產
   強制執行拍賣（俗稱金拍屋）時，長格式字軌是 `{地}金`：
   | 字軌 | 委託法院 | 104woo 法院代碼 |
   |------|----------|-----------------|
   | 南金 | 臺南地院 | TND |
   | 雄金 | 高雄地院 | KSD |
   | 橋金 | 橋頭地院 | CTD |
   | 屏金 | 屏東地院 | PTD |
   短格式則在尾端放類別標記 `金`。原本只處理法院自辦的 `司執`。
3. **流水號的前導零沒去掉**（長格式 `第000582號`、短格式 `582`）

案號結構（以 `114雄金職酉字第000229號` 為例）：
`114` 年度｜`雄金` 法院字軌｜`職` 業務性質｜`酉` 承辦股別｜`000229` 流水號。

### 實際損害

| 物件 | 損害 |
|------|------|
| **w1014** | 站上停在第一拍 2026-10-21（已過 → 被 `delist.js` 隱藏），實際是**第二拍 2026-11-11**、底價由 1960 萬降到 1568 萬。**一筆兩天後開標的物件在網站上看不到。** 已修復，代號與 tinyurl 保留 |
| **w346** | 已經被刪掉，tinyurl `2ysrzpqe` 失效。這筆不是正規化問題——`TND114司執清字第173198號` 與 `TND115司執明字第118515號` 真的是不同執行案號。後繼物件是 w1189 |

### 失效鏈（兩個 bug 串起來才會致命）

```
案號比不到  →  落到「地址二次保險」 →  當重複整列丟掉
            →  物件停在舊拍別  →  被 delist.js 隱藏
            →  滿 30 天被 purge 刪除
            →  下次再出現時開新代號、換新 tinyurl，舊連結全部失效
```

第二段是另一個獨立的 bug：路由只有兩條明路，**第三條是隱性的**——
「新案號 + 既有地址」沒有任何分支接它，整列丟掉。

### 處置（`publish_new.py`，commit `b4856b9`）

- 新鍵值：`法院|年度|業務+股別|流水號(去前導零)|標別`
- 🔴 **拍賣類別（法／金）刻意不進鍵值**：長短格式不一定都帶，
  `CTD114司執竹字第30053號`（有司執）↔ `CTD114竹30053`（尾端沒有法）就是一組。
  放進鍵值反而會讓它們比不到。類別只用來識別並剝除。
- 「新案號 + 既有地址」改為**就地更新保留 tinyurl**（2026-11-09 使用者決定）。
  `old["case"]` 會更新成新案號，而且**案號有變一律視為需要更新**——
  投標人靠案號找案子，頁面留著舊案號會害人投錯標。
- `pick_best` 對更新清單改以「對應到的既有物件代號」分組，
  避免同地址的多個不同案號把同一個物件更新好幾次。

### 上線前的驗證門檻

🔴 **改案號比對規則時，「新增碰撞 0 組」是錯的門檻**——
把長短格式併起來正是目的，一定會新增碰撞組。
**正確的門檻是「不可把不同拍賣類別（法／金）的案號併在一起」。**
驗收腳本已常駐：`法拍 104` 的 **`verify_canon_case.py`**，改完 canon_case 必跑。
它檢查 (a) 五個已知案例（含兩個必須判為不同的反例）(b) 正規化涵蓋率
(c) 每個碰撞組內的拍賣類別一致。退出碼 0 才可上線。

```powershell
python verify_canon_case.py          # 預設用 output/ 裡最新的爬蟲檔
```

實測結果：正規化涵蓋率 422 → **550/550**；新增合併 1 組（w1014 長短格式，同為金拍）；
類別混用 0 組；`…54742` vs `…54742二` 與 w346 的兩個案號都仍判為不同鍵。

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

## ⚠️ 待處理：`法拍 104` 的 CLAUDE.md 有疑似誤刪

2026-11-09 發現該 repo 的 `CLAUDE.md` 有一份**未 commit 的破壞性改動**（2 行新增、17 行刪除）：
GitHub 倉庫 URL 被清成空白、「自動下架」說明變成空行、整個「GitHub Pages 版」章節被刪掉。
看起來是編輯被截斷，不像刻意修改。**沒有 commit，原檔還在 HEAD 裡**。
還原方式（確認過才做）：

```powershell
git -C "G:\我的雲端硬碟\ai agent\法拍 104" checkout -- CLAUDE.md
```

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

- 🔴 **自癒對 `104woo.html` 有額外檢查，不要拿掉。**
  白名單裡其他檔案（`wNNN/index.html`、`card.jpg`、`hero.jpg`、`voice.mp3`、底圖）
  產線都會完整重生，人手改了下次上架也會被蓋掉，所以自動收拾不會毀掉什麼。
  **但 `104woo.html` 不是**——`publish_new.py` 只替換 `const BASE_ITEMS = ` 那一行，
  其餘版面、CSS、JS 全是手工維護的。改了版面沒 commit 的話，自癒會把它推上線，
  而且產線**不會**蓋掉它，是真的生效。
  所以自癒要收 `104woo.html` 之前，會先確認 diff 只動到 BASE_ITEMS 那一行；
  動到別的行就判定為人工修改而停下來。被刪除（`D`）也一律不收——
  總覽頁被刪還自動 commit 的話，整個網站會空掉。
  （四個情境實測過：乾淨、只動 BASE_ITEMS、只動版面、兩者都動。）

- 🔴 **會動到檔案的測試，一定要先 assert 要改的字串真的存在。**
  上面那個檢查，第一版的測試用 `<head>` 當標記，但 `104woo.html` 裡根本沒有這個標籤
  （檔案從 `<meta charset>` 開始）。`replace` 什麼都沒換、檔案位元沒變，
  測試於是「通過」了卻什麼都沒測到，還讓我一度誤判 fsmonitor 的結論有問題。

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

- 時間：2026-11-09 18:00
- 更新者：Claude Code (Opus 5) @ KEN-PC
- Git push：✅ 已推（Queen-of-Auctions `a78e6e5`、法拍 104 `b4856b9`）
