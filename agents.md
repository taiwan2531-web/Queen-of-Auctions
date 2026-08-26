# 👑 法拍女王 陳慧瑜 物件網站（專案藍圖）

> 本檔為跨 Agent 通用的專案藍圖（AGENTS.md 開放標準）。任何 Agent 的每個 session 都應先讀本檔＋`handoff.md`。

## 專案簡介

維運「👑 法拍女王 陳慧瑜」的法拍物件網站，發布於 GitHub Pages：
<https://taiwan2531-web.github.io/Queen-of-Auctions/>

每筆物件是一個 `wNNN/` 資料夾（物件頁＋照片＋燒價圖＋真人克隆語音），
總覽頁 `104woo.html` 內的 `BASE_ITEMS` 是**物件資料的唯一真理源**。
物件從 104 法拍網爬蟲取得，經去重後由產線批次生成頁面，
語音以本機 GPU 跑 VoxCPM 克隆陳慧瑜本人音色。

**細節規範看 [CLAUDE.md](CLAUDE.md)（操作手冊）與 [CONTEXT.md](CONTEXT.md)（領域模型／共同詞彙）。**
本檔只放藍圖與進度，不重複那兩份的內容。

## 關鍵時程

- **2026-08-28**：跑 `python purge_expired.py --dry-run` 檢視到期物件（本批開標日多在 2026/09）
- 爬蟲上架節奏：約每 8～11 天一次（實績：7/24、8/2、8/10-11、8/21）

## 目標與路線圖

- [x] ~~下架規則收斂為單一真理源~~ → `104woo-assets/delist.js`（開標時刻＋3 小時）
- [x] ~~舊系統退役~~ → 刪除 `publisher.html`／`template.html`，改為 `publish_new.py` 批次產線
- [x] ~~照片燒上拍賣底價~~ → `burn_price.ps1`（`card.jpg` 660×340／`hero.jpg` 1422×840）
- [x] ~~手機滑動切換物件~~ → `104woo-assets/swipe-nav.js`
- [x] ~~縣市標籤錯置修正~~ → `fix_city_labels.py`
- [x] ~~語音改用本機 GPU~~ → `local_voice_batch.py`（約 29 秒/筆，雲端 CPU 要 20 分鐘）
- [x] ~~過期物件自動清除~~ → `purge_expired.py`
- [x] ~~流標重新排拍不再換短網址~~ → `publish_new.py` 同案號就地更新＋保留期 30 天（2026-08-22）
- [ ] 下次上架時驗證「有新物件＋有更新」混合情境（目前只驗證過純更新）
- [ ] 架構報告候選 B：頁面模板單一真理源（`build_page` 目前仍以某張物件頁為母版做字串替換）

## 資料夾結構

```
Queen-of-Auctions/
├── 104woo.html              總覽頁；BASE_ITEMS 是物件資料的唯一真理源
├── index.html               轉址頁 → 104woo.html
├── CLAUDE.md                操作手冊（產線順序、去重規則、生命週期）
├── CONTEXT.md               領域模型／共同詞彙
├── agents.md / handoff.md   專案藍圖與交接檔（本檔）
├── 104woo-assets/           共用資源
│   ├── delist.js            下架判定唯一真理源
│   ├── swipe-nav.js         手機滑動切換（385 頁共用）
│   ├── queen.png            人像（386 個頁面引用）
│   ├── 白底.jpg             queen.png 的去背來源
│   └── S__21946379.jpg      品牌宣傳圖
├── wNNN/                    物件（385 筆）
│   ├── index.html           物件頁（含 narrText 講稿）
│   ├── photo.jpg / map.jpg  原始底圖（約 22% 無實景照，改用地圖）
│   ├── card.jpg / hero.jpg  燒價圖（由 burn_price.ps1 生成）
│   └── voice.mp3            陳慧瑜克隆語音
├── voices/法拍女王 陳慧瑜/   參考音色（音色的唯一真理源）
├── obsidian/工作記錄.md      L3 詳細紀錄
├── output/                  生成檔（.gitignore；僅 price-overlay-preview.html 例外保存）
├── *.py / *.ps1             產線腳本（見 CLAUDE.md 的執行順序）
└── 3kagzo/ k2rojm/ ...      舊 hash 代號物件頁封存（12 個，不依賴 delist.js）
```

> ⚠️ 批次上架的產線主腳本 `publish_new.py` **不在本 repo**，
> 位於 `G:\我的雲端硬碟\ai agent\法拍 104\`（連同爬蟲），推送至 `taiwan2531-web/104woo`。
> 它的 `REPO` 常數寫死指向本 repo，搬動本資料夾時必須同步修改。

## 同步層級（本專案初始化至第 3 層級）

| 層級 | 平台 | 位置 | 讀取時機 |
|------|------|------|---------|
| L1 | 本地（GDrive） | `G:\我的雲端硬碟\ai agent\Queen-of-Auctions`（`agents.md`＋`handoff.md`） | 每個 session |
| L2 | GitHub | `taiwan2531-web/Queen-of-Auctions`（分支 `main`，GitHub Pages 由 main 發布） | 指定時 |
| L3 | Obsidian | `obsidian/工作記錄.md`（在 repo 內，非獨立 vault） | 有需要時 |

**相關 repo**：`taiwan2531-web/104woo`（`G:\我的雲端硬碟\ai agent\法拍 104`）＝ 爬蟲＋上架產線。

## 工作約定

- 任何 Agent、任何電腦：**開工先讀 `handoff.md`，收工必更新 `handoff.md`**
- 所有回應與文件使用繁體中文
- **只能有一份 clone**。2026-08-22 前 Google Drive 上有兩份同一 repo 的工作區，
  導致其中一份落後 61 個 commit 而無人察覺。收工時 `handoff.md` 的「更新者 @ 電腦名」欄位就是防這件事的。
- **產線有固定執行順序**（見 CLAUDE.md）：`fix_city_labels.py` 必須早於語音生成，
  因為它會改動 `narrText` 講稿。
- 上架前**必做重複比對**；同案號視情況「就地更新」而非開新代號，以免既有 tinyurl 失效。
- 兩支 `.ps1` 含中文，必須存成 **UTF-8 with BOM**（PowerShell 5.1 否則會用 ANSI 讀而解析失敗）。
  其餘 `.md`／`.py` 一律 **UTF-8 無 BOM**。
- 修改共用檔案前先讀最新內容，避免覆蓋其他 Agent 的變更
