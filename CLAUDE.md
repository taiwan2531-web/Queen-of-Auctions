# 法拍物件網頁發布工具專案指引 (CLAUDE.md)

本專案是用於管理與發布「👑 法拍女王 陳慧瑜」法拍物件之網頁工具。透過發布工具，使用者可直接發布新物件，物件頁將會被推送到 GitHub 倉庫，並在幾分鐘內自動由本地語音克隆工具（VoxCPM2）生成法拍女王陳慧瑜的真人克隆語音 `voice.mp3`。

## 三處同步對照表
* **本地專案路徑**：`g:\我的雲端硬碟\ai agent\Queen-of-Auctions`
* **GitHub 倉庫 URL**：`https://github.com/taiwan2531-web/Queen-of-Auctions`
* **Obsidian 資料夾路徑**：`g:\我的雲端硬碟\ai agent\Queen-of-Auctions\obsidian`

---

## 開發指引

### 專案結構
* `index.html`：物件總覽首頁。自動隱藏已過期的卡片。
* `publisher.html`：發布與管理（下架）物件的網頁工具。
* `template.html`：物件網頁的 HTML 模板，包含 `{{PLACEHOLDERS}}` 供發布工具替換。
* `[物件代號]/`：發布後產生的物件資料夾（代號為 `wNNN`），內含：
  * `index.html`：物件頁
  * `photo.jpg`：原始實景照（**約 22% 的物件沒有實景照，改放 `map.jpg` 地圖截圖**）
  * `card.jpg` / `hero.jpg`：由 `burn_price.ps1` 產生的**燒價圖**（見下節），原始底圖不會被改動
  * `voice.mp3`：真人克隆語音

### 照片底價標示（燒進圖片檔）
物件照片上會燒上「拍賣底價」，讓價格在 LINE／FB 分享縮圖也看得到（`og:image` 指向 `hero.jpg`）。

| 檔案 | 尺寸 | 樣式 | 用途 |
|------|------|------|------|
| `card.jpg` | 660×340 | 右下角深藍價格牌＋金色數字 | 總覽卡片（BASE_ITEMS 的 `thumb`） |
| `hero.jpg` | 1422×840 | 底部漸層＋超大白字＋單價 | 物件頁大圖、`og:image`、頁內詳細頁（`hero`） |

尺寸是照版面實際比例訂的，瀏覽器 `object-fit:cover` 才不會把價格裁掉；`.card .photo` 因此鎖成 `aspect-ratio:33/17`。

**新物件上架後務必補跑**（兩支都可重複執行、只讀原始底圖，隨時可刪衍生檔還原）：
```
powershell -File burn_price.ps1          # 生成 card.jpg / hero.jpg（-Force 可全部重做）
powershell -File apply_price_images.ps1  # 網頁改指向燒價圖（-WhatIf 可先預覽）
```
> ⚠ 兩支 `.ps1` 含中文，必須存成 **UTF-8 with BOM**，否則 PowerShell 5.1 會用 ANSI 讀而解析失敗。
> 底價若有異動，重跑 `burn_price.ps1 -Force` 重新生成即可。

### 批次上架前必做：重複檢查
上架新物件前，**務必先做重複比對**，確認沒有重複才生成頁面：
1. **案號正規化比對**：104 法拍網案號有長短兩種格式（`CTD114司執竹字第30053號` 與 `CTD114竹30053` 是同一案），須歸一化為「法院|年度|字|號碼|標別」後再比對。標別不同（如 `54742` 與 `54742二`）視為不同物件。
2. **與現有物件比對**：新資料的案號與地址，都要和 104woo.html 的 BASE_ITEMS 現有物件比對，已存在者跳過。
3. **批次內部去重**：同一物件常被多位仲介業務重複刊登（實測同案號最多被刊 7 次），同案號只保留一筆，優先保留**有照片**的版本，其次物件編號較小者。
4. **地址二次保險**：不同案號但同地址也視為重複。
（2026-07-24 實測：爬蟲 1305 筆中候選 193 筆，去重後實際新物件僅 54 筆。）

### 物件生命週期：下架與刪除
1. **下架**：開標時刻 ＋ **3 小時** 自動下架（規則唯一真理源：`104woo-assets/delist.js`）。
   開標時間為 `00:00`／空／無法解析時視為「時間未知」，保守以當日 **17:00** 起算。
2. **刪除**：下架後再滿 **7 天**，即刪除該物件（資料夾＋總覽 BASE_ITEMS 資料），並自動修補相鄰物件的導覽鏈。
   * 執行：`python purge_expired.py --dry-run`（先預覽）→ `python purge_expired.py --push`
   * 可用 `--days N` 調整保留期。刪除後檔案仍留在 git 歷史，必要時可復原。
   * 注意：刪除後該物件的 tinyurl 短網址與既有分享連結會失效。

### 語音生成（本機 GPU，優先於雲端）
本機有 RTX 5070，跑一筆約 **38 秒**；雲端 GitHub Actions 為 CPU，一筆約 20 分鐘（且有 6 小時上限）。
新物件上架後補語音，優先用本機：
```
& "C:\Users\ken\voxcpm\Scripts\python.exe" local_voice_batch.py
```
`local_voice_batch.py` 會掃出所有缺 `voice.mp3` 的物件，模型只載入一次，逐筆生成並每 10 筆 commit，最後自動 push。

### 語音克隆機制
本地語音克隆腳本 `auto_voice.py`（位於克隆專案目錄下）會自動執行以下流程：
1. 檢測 GitHub 倉庫上是否有新物件上架且缺少 `voice.mp3`。
2. 抓取 `index.html` 中的 `narrText` 講稿。
3. 使用 `VoxCPM2`（陳慧瑜克隆模型）生成克隆語音，並使用 `ffmpeg` 轉成 `voice.mp3`。
4. 自動將 `voice.mp3` commit 並 push 上 GitHub。
