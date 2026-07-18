# 法拍物件網頁發布工具專案指引 (CLAUDE.md)

本專案是用於管理與發布「👑 法拍女王 陳慧瑜」法拍物件之網頁工具。透過發布工具，使用者可直接發布新物件，物件頁將會被推送到 GitHub 倉庫，並在幾分鐘內自動由本地語音克隆工具（VoxCPM2）生成法拍女王陳慧瑜的真人克隆語音 `voice.mp3`。

## 三處同步對照表
* **本地專案路徑**：`g:\我的雲端硬碟\AntiGravity\法拍物件網頁發布工具`
* **GitHub 倉庫 URL**：`https://github.com/taiwan2531-web/Queen-of-Auctions`
* **Obsidian 資料夾路徑**：`g:\我的雲端硬碟\AntiGravity\法拍物件網頁發布工具\obsidian`

---

## 開發指引

### 專案結構
* `index.html`：物件總覽首頁。自動隱藏已過期的卡片。
* `publisher.html`：發布與管理（下架）物件的網頁工具。
* `template.html`：物件網頁的 HTML 模板，包含 `{{PLACEHOLDERS}}` 供發布工具替換。
* `[物件代號]/`：發布後產生的物件資料夾，內含 `index.html`、`[物件代號].jpg`（圖片）與 `voice.mp3`（真人語音）。

### 語音克隆機制
本地語音克隆腳本 `auto_voice.py`（位於克隆專案目錄下）會自動執行以下流程：
1. 檢測 GitHub 倉庫上是否有新物件上架且缺少 `voice.mp3`。
2. 抓取 `index.html` 中的 `narrText` 講稿。
3. 使用 `VoxCPM2`（陳慧瑜克隆模型）生成克隆語音，並使用 `ffmpeg` 轉成 `voice.mp3`。
4. 自動將 `voice.mp3` commit 並 push 上 GitHub。
