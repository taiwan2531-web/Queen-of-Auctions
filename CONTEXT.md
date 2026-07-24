# 領域模型 CONTEXT.md — 法拍物件網頁發布工具

本檔記錄專案的共同詞彙（ubiquitous language）。命名物件、模組、函式時，優先沿用這裡的詞。

## 詞彙

### 物件（Property / Item）
一筆法拍標的。權威資料源是 `104woo.html` 內的 `BASE_ITEMS`（陣列，每筆含案號、地址、開標日、底價、機能等），代號為 `wNNN`（如 `w357`）。每筆物件對應一個 `wNNN/index.html` 物件頁。

### 物件生命週期（Object lifecycle）
物件從「上架 → 開標 → 下架」的狀態流轉。目前系統只自動處理「下架」這一個轉換，判準見「下架判定」。

### 下架判定（Delisting predicate）
判斷一筆物件是否已到期下架的規則，是本專案的**單一真理源**，實作於 `104woo-assets/delist.js`。

- **規則**：開標時刻 + `DELIST_HOURS`（＝3）小時後即下架。
- **時間未知處理**：開標時間為 `00:00`、空值或無法解析時，視為「未知」，保守以當日 **17:00** 起算，避免在真正開標前就下架。
- **時區**：固定台灣 `+08:00`。
- **對外 interface**：
  - `Delist.isExpired(dateISO, time, nowMs?)` — 純函式，回傳布林。總覽用它過濾卡片。
  - `Delist.applyToPage()` — 物件頁載入時讀 `<body data-auction / data-auction-time>`，過期則套 `expired` class、改標題。
- **消費者**：`104woo.html`（總覽列表與詳細頁）＋每一張 `wNNN/index.html`（載入 `../104woo-assets/delist.js`）。
- **測試**：`delist.test.html`（雙擊即跑，釘住規則與 `00:00` 邊界）。

> 這個 seam 收斂前，同一規則曾散落於 `104woo.html`、`template.html`、410 張物件頁與生成器，出現「3 小時／3 天／1 天」三種互相矛盾的版本。deletion test：刪掉 `delist.js`，下架複雜度會重現在所有消費者——證明它 earning its keep。

### 生成器（Generator）
把物件資料變成物件頁的東西。有兩個 adapter，共用同一個規則 seam（`delist.js`）、同一頁面模板慣例：
- `publisher.html` + `template.html`：瀏覽器手動發布單筆，填 `{{PLACEHOLDER}}`。
- `publish_new.py`（位於「法拍 104」專案）：批次產線，一次生成多筆。

生成器**不再內嵌下架規則**，只輸出 `<body data-auction>` data 屬性 + `<script src="../104woo-assets/delist.js">`。

### 語音克隆（Voice clone）
物件頁的 `voice.mp3`，由「法拍女王 陳慧瑜」參考音色（`voices/法拍女王 陳慧瑜/`）克隆。雲端 `sync_voices.py`（GitHub Actions，缺 `voice.mp3` 才生成）或本地流程產生。參考音色是唯一真理源，換音色只需替換該資料夾內的 `ref_voice.wav` + `prompt.txt`。
