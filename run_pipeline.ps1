<#
.SYNOPSIS
    法拍女王網站批次上架產線（無人值守版）。

.DESCRIPTION
    把 skill `auction-publish` 的步驟改寫成純腳本，交給 Windows 工作排程器執行。

    為什麼不用 Claude Code 排程（2026-09-05 改）：
      2026-08-29、09-02、09-05 連續三次自動排程都在第 3 個指令（git pull）就停住，
      13 秒內結束、什麼都沒做。原因是每個會寫入或連外的指令都會攔一次權限確認，
      而排程執行時沒有人可以按。加 permissions.allow 沒解決（指令是
      `cd "..." && git pull ...` 這種複合形狀，前綴比對打不中）。

      回到第一性原理：這條產線每一步都是固定順序、固定參數，護欄是三個數字比較，
      commit 訊息可以模板化——**它根本不需要 LLM**。當初放進 Claude Code 是因為
      skill 寫在那裡（沿用），不是因為工作需要 agent（推導）。
      改成腳本後沒有權限層，也不需要 Claude Code 開著。

.PARAMETER DryRun
    只跑到爬蟲＋dry-run 統計就停，不寫任何檔案、不 commit。用來驗證環境。

.PARAMETER SkipCrawl
    不跑爬蟲，直接用 output\ 裡最新的爬蟲 JSON。省 25 分鐘，用於重跑失敗的後段。

.PARAMETER NoPush
    跑完 commit 但不 push。

.PARAMETER MaxPages
    爬蟲頁數，預設 20。**不要調到 60**：2026-08-11 實測多跑一小時、新物件 0 筆。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File run_pipeline.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File run_pipeline.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [switch] $DryRun,
  [switch] $SkipCrawl,
  [switch] $NoPush,
  [int]    $MaxPages = 20
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# ---------- 路徑 ----------
$SITE_REPO  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CRAWL_REPO = 'G:\我的雲端硬碟\ai agent\法拍 104'
$PY_CRAWL   = 'C:\Users\ken\.venvs\fapai104\Scripts\python.exe'
$PY_VOICE   = 'C:\Users\ken\.venvs\voxcpm\Scripts\python.exe'

$LOG_DIR = Join-Path $SITE_REPO 'output\pipeline-logs'
if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Force $LOG_DIR | Out-Null }
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LOG     = Join-Path $LOG_DIR "$stamp.log"
$STATS   = Join-Path $LOG_DIR "$stamp.stats.json"

# ---------- 護欄門檻 ----------
$MIN_CRAWL   = 800    # 正常 1300~1450 筆。太少代表網站改版或網路異常，資料不可信
$MAX_NEW     = 200    # 正常一批 50~180 筆。暴增通常是案號比對壞了
$MAX_UPDATES = 200

Start-Transcript -Path $LOG -Force | Out-Null

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Die([string]$m, [int]$code) {
  Say "❌ 中止：$m"
  Say "   工作區狀態如下（供你判斷要不要手動收拾）："
  & git -C $SITE_REPO status --short
  Stop-Transcript | Out-Null
  exit $code
}
function NeedOk([string]$what) { if ($LASTEXITCODE -ne 0) { Die "$what 失敗（exit $LASTEXITCODE）" 2 } }

Say "===== 法拍上架產線開始（log: $LOG）====="

# ---------- 0. 前置檢查 ----------
Say '0. 前置檢查'
$dirty = & git -C $SITE_REPO status --porcelain
if ($dirty) {
  Say '工作區有未 commit 的變動：'
  $dirty | ForEach-Object { Say "    $_" }
  Die '工作區不乾淨。那可能是你做到一半的東西，腳本不會自行 commit 或丟棄' 3
}
& git -C $SITE_REPO pull --ff-only origin main
NeedOk 'git pull'

# ---------- 1. 爬蟲 ----------
if ($SkipCrawl) {
  Say '1. 略過爬蟲（-SkipCrawl）'
} else {
  Say "1. 爬蟲（4 縣市 × $MaxPages 頁，約 25 分鐘）"
  Push-Location $CRAWL_REPO
  & $PY_CRAWL crawler_104woo_property.py --city 嘉義縣 台南市 高雄市 屏東縣 --sort-date --pending-only --max-pages $MaxPages
  $rc = $LASTEXITCODE
  Pop-Location
  if ($rc -ne 0) { Die "爬蟲失敗（exit $rc）" 2 }
}

$json = Get-ChildItem (Join-Path $CRAWL_REPO 'output\104woo_物件_4縣市_*.json') |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $json) { Die '找不到任何爬蟲 JSON' 2 }
Say "   使用爬蟲檔：$($json.Name)（$($json.LastWriteTime.ToString('MM-dd HH:mm'))）"

# ---------- 2. dry-run 並檢查護欄 ----------
Say '2. dry-run 並檢查護欄'
Push-Location $CRAWL_REPO
& $PY_CRAWL publish_new.py $json.FullName --dry-run --stats-out $STATS
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Die "dry-run 失敗（exit $rc）" 2 }
if (-not (Test-Path $STATS)) { Die 'dry-run 沒有產出 stats.json' 2 }

$s = Get-Content $STATS -Raw -Encoding UTF8 | ConvertFrom-Json
Say ("   爬蟲 {0} 筆｜現有 {1} 筆｜新物件 {2} 筆｜就地更新 {3} 筆" -f $s.crawl, $s.existing, $s.new, $s.updates)

if ($s.crawl   -lt $MIN_CRAWL)   { Die "爬蟲只有 $($s.crawl) 筆（門檻 $MIN_CRAWL）——資料不可信，不上架" 1 }
if ($s.new     -gt $MAX_NEW)     { Die "新物件 $($s.new) 筆超過門檻 $MAX_NEW——疑似案號比對壞掉" 1 }
if ($s.updates -gt $MAX_UPDATES) { Die "更新 $($s.updates) 筆超過門檻 $MAX_UPDATES——疑似案號比對壞掉" 1 }

if ($s.new -eq 0 -and $s.updates -eq 0) {
  Say '✅ 無異動（新物件 0 筆、更新 0 筆），結束。'
  Stop-Transcript | Out-Null
  exit 0
}
if ($DryRun) {
  Say '✅ -DryRun：到此為止，沒有寫入任何檔案。'
  Stop-Transcript | Out-Null
  exit 0
}

# ---------- 3. 實際上架 ----------
Say '3. publish_new.py（實際寫入）'
Push-Location $CRAWL_REPO
& $PY_CRAWL publish_new.py $json.FullName --stats-out $STATS
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Die "上架失敗（exit $rc）" 2 }

$s2 = Get-Content $STATS -Raw -Encoding UTF8 | ConvertFrom-Json
$nAdd = @($s2.added).Count
$nUpd = @($s2.updated).Count
Say "   實際新增 $nAdd 筆、更新 $nUpd 筆"
if ($nAdd -ne $s.new -or $nUpd -ne $s.updates) {
  Die "實際筆數（$nAdd/$nUpd）與 dry-run（$($s.new)/$($s.updates)）不符" 2
}

# ---------- 4~7. 後處理（順序不可調換）----------
Say '4. fix_city_labels.py（必須早於語音，會改講稿）'
& $PY_CRAWL (Join-Path $SITE_REPO 'fix_city_labels.py'); NeedOk 'fix_city_labels'

Say '5. burn_price.ps1'
& powershell -ExecutionPolicy Bypass -File (Join-Path $SITE_REPO 'burn_price.ps1'); NeedOk 'burn_price'

Say '6. apply_price_images.ps1'
& powershell -ExecutionPolicy Bypass -File (Join-Path $SITE_REPO 'apply_price_images.ps1'); NeedOk 'apply_price_images'

Say '7. apply_swipe_nav.py'
& $PY_CRAWL (Join-Path $SITE_REPO 'apply_swipe_nav.py'); NeedOk 'apply_swipe_nav'

# ---------- 8. commit 主體（在語音之前，語音失敗時工作也已保住）----------
Say '8. commit 主體'
& git -C $SITE_REPO add -A
NeedOk 'git add'
$msg = @"
feat(items): 上架 $nAdd 筆新物件、就地更新 $nUpd 筆（自動排程）

爬蟲 $($s.crawl) 筆 → 案號正規化去重後分流：
新案號 $nAdd 筆開新代號，同案號 $nUpd 筆就地更新（代號與 tinyurl 不變）。

由 run_pipeline.ps1 自動執行，爬蟲檔 $($json.Name)。
產線順序：publish_new → fix_city_labels → burn_price
→ apply_price_images → apply_swipe_nav → local_voice_batch

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
"@
$msgFile = Join-Path $LOG_DIR "$stamp.commitmsg.txt"
Set-Content -Path $msgFile -Value $msg -Encoding utf8
& git -C $SITE_REPO commit -q -F $msgFile
NeedOk 'git commit'
Say ("   " + (& git -C $SITE_REPO log -1 --format='%h %s'))

# ---------- 9. 語音（會自己 commit 並 push）----------
Say '9. local_voice_batch.py（約 28 秒/筆）'
$voiceArgs = @((Join-Path $SITE_REPO 'local_voice_batch.py'))
if ($NoPush) { $voiceArgs += '--no-push' }
& $PY_VOICE $voiceArgs
NeedOk 'local_voice_batch'

# ---------- 10. 確認全部推上去 ----------
if (-not $NoPush) {
  Say '10. 確認推送'
  & git -C $SITE_REPO push origin main
  if ($LASTEXITCODE -ne 0) { Say '   （push 回報非 0，多半是語音腳本已經推過，下面用 ahead 數確認）' }
  $ahead = (& git -C $SITE_REPO rev-list '@{u}..HEAD' --count)
  if ($ahead -ne '0') { Die "還有 $ahead 個 commit 沒推上去" 2 }
  Say '   ✅ 已與 origin/main 同步'
}

# ---------- 11. 驗證 ----------
Say '11. 資料完整性檢查'
$dirs = @(Get-ChildItem -Directory $SITE_REPO -Filter 'w*' | Where-Object { $_.Name -match '^w\d+$' })
$missing = @()
foreach ($d in $dirs) {
  foreach ($f in @('index.html','voice.mp3','card.jpg','hero.jpg')) {
    if (-not (Test-Path (Join-Path $d.FullName $f))) { $missing += "$($d.Name)/$f" }
  }
}
Say "   物件資料夾 $($dirs.Count) 個｜缺件 $($missing.Count) 個"
if ($missing.Count -gt 0) {
  $missing | Select-Object -First 10 | ForEach-Object { Say "     缺 $_" }
  Die "有 $($missing.Count) 個檔案沒生成" 2
}

Say "===== 完成：新增 $nAdd 筆、更新 $nUpd 筆 ====="
Stop-Transcript | Out-Null
exit 0
