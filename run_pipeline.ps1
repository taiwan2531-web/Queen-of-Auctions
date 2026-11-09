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

# ---------- 退出碼 ----------
# 🔴 用 241–253，不要用 1–6。
# 工作排程器的「上次執行結果」會把退出碼當 Win32 錯誤碼翻成訊息：
#   1 功能錯誤｜2 系統找不到指定的檔案｜3 系統找不到指定的路徑
#   4 系統無法開啟檔案｜5 存取被拒｜6 控制代碼無效
# 產線回 3（工作區不乾淨）會顯示成「系統找不到指定的路徑」，
# 回 5（等不到腳本）會顯示成「存取被拒」——往完全錯的方向查。
# 241–253 沒有對應的系統訊息（net helpmsg 實測），排程器只顯示裸退出碼。
#   0 成功或無異動
#   241 護欄觸發   242 執行失敗   243 工作區不乾淨
#   244 假成功     245 等不到腳本 246 已有另一個實例在跑
#
# ---------- 護欄門檻 ----------
$MIN_CRAWL   = 800    # 正常 1300~1450 筆。太少代表網站改版或網路異常，資料不可信
$MAX_NEW     = 200    # 正常一批 50~180 筆。暴增通常是案號比對壞了
$MAX_UPDATES = 200
$MAX_PURGE   = 300    # 單次清除上限。正常一次 60~130 筆；暴增代表下架判定出問題

Start-Transcript -Path $LOG -Force | Out-Null

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Die([string]$m, [int]$code) {
  Say "❌ 中止：$m"
  Say "   工作區狀態如下（供你判斷要不要手動收拾）："
  & git -C $SITE_REPO status --short
  Stop-Transcript | Out-Null
  exit $code
}
function NeedOk([string]$what) { if ($LASTEXITCODE -ne 0) { Die "$what 失敗（exit $LASTEXITCODE）" 242 } }

function GitLogged([string[]]$ArgList) {
  # 2026-11-09：Start-Transcript 不收原生指令的 stderr（PowerShell 5.1 的限制）。
  # 那天第 8 步 git add 回 exit 128，fatal 訊息完全沒留下來——只知道退出碼，
  # 查不出原因。所有「退出碼有意義」的 git 呼叫都走這裡，把 stderr 寫進 log。
  #
  # ⚠ 5.1 的 2>&1 會把原生指令的 stderr 包成 ErrorRecord，而本檔的
  #   $ErrorActionPreference = 'Stop' 會讓它變成終止錯誤。git push／fetch 連正常
  #   進度都寫 stderr，所以這段必須先降成 Continue，結束再還原。
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $raw  = & git -C $SITE_REPO @ArgList 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  foreach ($l in @($raw)) { $t = [string]$l; if ($t.Trim()) { Say "      git: $t" } }
  $global:LASTEXITCODE = $code
}

function Push-Pending([string]$why) {
  # 2026-11-09 審查發現（主張 6）：第 0 步自我修復建立的 commit，在「無異動」
  # 與 -DryRun 這兩條 exit 0 路徑上永遠不會被推送。本機會一直領先遠端，
  # 而且因為退出碼是 0，沒有任何人會發現。
  # （2026-08-22 之前有過落後 61 個 commit 19 天沒人察覺的前例。）
  if ($NoPush) { Say "   -NoPush：$why，不推送"; return }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & git -C $SITE_REPO fetch -q origin 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
  $ahead = & git -C $SITE_REPO rev-list --count 'origin/main..HEAD'
  if ($LASTEXITCODE -ne 0) { Say '   ⚠ 算不出領先遠端的 commit 數，略過補推'; return }
  if ([int]$ahead -le 0) { return }
  Say "   有 $ahead 個 commit 未推送（$why），推送中"
  GitLogged @('push', 'origin', 'main')
  NeedOk 'git push（補推未推送的 commit）'
}

# ---------- 清除下架滿 30 天的物件 ----------
# 排在最後：上架失敗就不會連帶清除。無異動時也要跑，否則過期物件永遠不會被清。
$script:nPurge = 0
function Invoke-Purge {
  Say '清除過期物件'
  $pstats = Join-Path $LOG_DIR "$stamp.purge.json"
  & $PY_CRAWL (Join-Path $SITE_REPO 'purge_expired.py') --dry-run --stats-out $pstats | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "purge dry-run 失敗（exit $LASTEXITCODE）" 242 }
  $ps = Get-Content $pstats -Raw -Encoding UTF8 | ConvertFrom-Json
  $script:nPurge = [int]$ps.purge
  if ($script:nPurge -eq 0) { Say "   沒有需要清除的物件"; return }
  if ($script:nPurge -gt $MAX_PURGE) { Die "待清除 $($script:nPurge) 筆超過門檻 $MAX_PURGE——疑似下架判定出問題，不清除" 241 }
  Say "   清除 $($script:nPurge) 筆（保留 $($ps.kept) 筆）"
  $pushArg = if ($NoPush) { @() } else { @("--push") }
  & $PY_CRAWL (Join-Path $SITE_REPO 'purge_expired.py') --stats-out $pstats @pushArg
  NeedOk "purge_expired"
}

Say "===== 法拍上架產線開始（log: $LOG）====="

# ---------- 單一實例互斥鎖 ----------
# 2026-11-09：23:49 與 00:02 兩個實例同時在跑，兩邊都算出同樣的 98 新／120 更新，
# 同時進入 publish_new.py 大量寫檔，後者在第 8 步 git add 回 exit 128 而中止。
# 排程任務本身有 MultipleInstances IgnoreNew，但手動呼叫（或請 Claude Code 代跑）
# 完全沒有保護——這條產線跑 2 小時，重疊的機會不小。
#
# 用具名 Mutex 而不是鎖檔：鎖由 OS 持有，程序被砍或當掉時自動釋放。
# 鎖檔留在磁碟上的話，當掉一次就要人工清，等於再加一個「無聲卡住」的機制——
# 這個 repo 已經因為「工作區永遠不乾淨」空轉過 13 天，不要重蹈。
$script:Lock = New-Object System.Threading.Mutex($false, 'Global\QueenOfAuctions-Pipeline')
$gotLock = $false
try { $gotLock = $script:Lock.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $gotLock = $true }  # 前一個實例沒正常結束
if (-not $gotLock) {
  Say '❌ 已有另一個產線實例在執行，本次不啟動'
  Say '   兩個實例會搶同一批檔案。2026-11-09 就是這樣讓第 8 步 git add 回 exit 128。'
  Stop-Transcript | Out-Null
  exit 246
}

# ---------- 0. 前置檢查 ----------
Say '0. 前置檢查'

# fsmonitor 防呆。
# 2026-11-09 對照實驗（每組 1440 次檢查）：
#     檔案系統            fsmonitor 關   fsmonitor 開
#     G:（Google Drive）  0 次漏看       720/720 已追蹤檔案漏看（100%）
#     C:（NTFS）          0 次漏看       0 次漏看
# 是 fsmonitor × Google Drive 的組合：git 沒壞（C: 上開關都正常），
# Drive 單獨也沒問題（關掉後 0 漏看）。而且只漏「被修改的已追蹤檔案」，
# 未追蹤的新檔案一次都沒漏——與 8/28、10/13、10/26、11/9 四次事故完全吻合
# （漏掉的全是 104woo.html 與導覽頁，新增的 wNNN/ 資料夾一次都沒漏）。
# git 升級、其他工具或手動設定都可能把它打開，所以每次跑之前檢查一次。
# 這是本機效能設定，關掉只讓 git status 慢約 1 秒，沒有資料風險。
$fsm = & git -C $SITE_REPO config --get core.fsmonitor
if ($fsm -and $fsm -ne 'false') {
  Say "⚠ core.fsmonitor = $fsm"
  Say '   在 Google Drive 上這會讓 git 看不到被修改的已追蹤檔案（實測 100% 漏看），自動關閉'
  GitLogged @('config', 'core.fsmonitor', 'false')
  GitLogged @('config', 'core.untrackedCache', 'false')
  GitLogged @('fsmonitor--daemon', 'stop')
  GitLogged @('update-index', '--really-refresh')
  $global:LASTEXITCODE = 0   # 上面幾個就算回非 0 也不該讓產線停下來
}
$dirty = & git -C $SITE_REPO status --porcelain
if ($dirty) {
  Say '工作區有未 commit 的變動：'
  $dirty | ForEach-Object { Say "    $_" }

  # 自我修復：只收拾「已追蹤的產線產物被修改」這一種。
  # 2026-10-26 的 w629/index.html 就是這種——purge 寫好的導覽修補因 Google Drive
  # 可見性延遲沒進 commit，工作區從此不乾淨，之後四次排程全部 exit 3、13 天無聲空轉。
  #
  # 刻意不收拾的情況，因為它們代表「有人做到一半」或「上架被中斷」：
  #   ?? wNNN/        中斷的上架留下的孤兒資料夾；自動 commit 會讓 BASE_ITEMS 與資料夾不一致
  #   M  *.py / *.ps1 / *.md   有人在改程式或文件
  # 哪些檔案是產線自己產的（2026-11-09 擴充）：
  # 原本只收 104woo.html 與 wNNN/index.html，漏掉 burn_price.ps1 產的
  # card.jpg／hero.jpg、local_voice_batch.py 產的 voice.mp3、以及底圖。
  # purge 刪一個資料夾時這些會全部以 ' D' 出現，一個都不收的話整批卡死。
  $own = '^(104woo\.html|w\d+/(index\.html|card\.jpg|hero\.jpg|voice\.mp3|photo\.jpg|map\.jpg))$'
  # 哪些狀態碼算「產線做到一半」（2026-11-09 擴充）：
  #   ' M' 已追蹤被改、未 stage        'M ' 已 stage 未 commit
  #   'MM' stage 後又被改              ' D' 工作區刪除（purge 刪資料夾逾時）
  #   'D ' 已 stage 的刪除
  # 🔴 未追蹤的 '??' 一律不收。那代表中斷的上架留下孤兒資料夾，
  #    自動 commit 會讓 BASE_ITEMS 與資料夾不一致（2026-09-20 有過 35 個）。
  $okCodes = @(' M', 'M ', 'MM', ' D', 'D ')

  function Test-OverviewIsPipelineOnly {
    # 104woo.html 只有 `const BASE_ITEMS = ` 那一行是產線生成的
    # （publish_new.py 只替換那段 JSON），其餘版面／CSS／JS 都是手工維護。
    # 所以不能跟 wNNN/* 一樣無條件放行——改了版面沒 commit 的話，
    # 自癒會把它推上線，而且產線不會蓋掉它，是真的生效。
    $d = & git -C $SITE_REPO diff HEAD -- '104woo.html'
    $other = @($d | Where-Object {
      ($_ -match '^[+-]') -and
      ($_ -notmatch '^(\+\+\+|---)') -and
      ($_ -notmatch '^[+-]const BASE_ITEMS = ')
    })
    return , $other
  }

  $unsafe = @()
  foreach ($ln in $dirty) {
    if ($ln.Length -lt 4) { $unsafe += $ln; continue }
    $code = $ln.Substring(0, 2)
    $path = $ln.Substring(3).Trim().Trim('"')
    if ($okCodes -notcontains $code -or $path -notmatch $own) { $unsafe += $ln; continue }

    if ($path -eq '104woo.html') {
      # 刪掉總覽頁絕不是產線行為——真讓它自動 commit，整個網站會空掉
      if ($code -eq ' D' -or $code -eq 'D ') {
        Say '   104woo.html 被刪除——這絕不是產線行為'
        $unsafe += $ln; continue
      }
      $other = Test-OverviewIsPipelineOnly
      if ($other.Count -gt 0) {
        Say "   104woo.html 的改動不只 BASE_ITEMS（另有 $($other.Count) 行），像是有人在改版面："
        $other | Select-Object -First 6 | ForEach-Object { Say "       $_" }
        $unsafe += $ln; continue
      }
    }
  }
  if ($unsafe.Count -gt 0) {
    Say '   其中這些不是產線產物，不自動處理：'
    $unsafe | ForEach-Object { Say "     $_" }
    Die '工作區不乾淨。那可能是你做到一半的東西，腳本不會自行 commit 或丟棄' 243
  }

  Say '   全部是產線產物（已追蹤檔案被修改），自動收拾後繼續'
  # 只 add 上面逐筆檢查過的那幾個路徑。
  # 原本寫 `git add -A`：判斷只看白名單，卻把整個工作區都收進來。
  # 判斷與 add 之間只要有新檔案冒出來（這個 repo 在 Google Drive 的虛擬檔案系統上，
  # 正是會這樣），就會把從沒檢查過的東西一起 commit 進去。2026-11-09 審查主張 2。
  $repairPaths = @()
  foreach ($ln in $dirty) { $repairPaths += $ln.Substring(3).Trim().Trim('"') }
  GitLogged (@('add', '--') + $repairPaths)
  NeedOk 'git add（自我修復）'
  # 🔴 自癒被觸發 = 上一次有漏檔。不要把它當成「已經處理好了」而忽略，
  #    要回頭查上一次為什麼沒收乾淨（最常見的原因是 fsmonitor 又被打開）。
  Say "   ⚠ 自癒被觸發代表上一次執行有漏檔，請查上一次的 log"
  $rmsg = Join-Path $LOG_DIR "$stamp.repair.txt"
  [IO.File]::WriteAllText($rmsg, @"
chore: 自動收拾產線殘留（$($dirty.Count) 個檔案）

$($repairPaths -join "`n")

上一次執行寫出的產線產物沒進 commit，工作區因此不乾淨。
repo 在 Google Drive 上，剛寫入的檔案不保證立刻被 git 看到——
2026-10-26 的 w629/index.html 就是這樣，害後續四次排程連續 exit 3、13 天沒有更新。

只有「已追蹤的 104woo.html 或 wNNN/index.html 被修改」會自動收拾；
未追蹤的新資料夾（可能是中斷的上架）仍然會讓產線停下來等人處理。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
"@, (New-Object Text.UTF8Encoding $false))
  GitLogged @('commit', '-q', '-F', $rmsg)
  NeedOk 'git commit（自我修復）'
  Say ("   " + (& git -C $SITE_REPO log -1 --format='%h %s'))
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
  if ($rc -ne 0) { Die "爬蟲失敗（exit $rc）" 242 }
}

$json = Get-ChildItem (Join-Path $CRAWL_REPO 'output\104woo_物件_4縣市_*.json') |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $json) { Die '找不到任何爬蟲 JSON' 242 }
Say "   使用爬蟲檔：$($json.Name)（$($json.LastWriteTime.ToString('MM-dd HH:mm'))）"

# ---------- 2. dry-run 並檢查護欄 ----------
Say '2. dry-run 並檢查護欄'
Push-Location $CRAWL_REPO
& $PY_CRAWL publish_new.py $json.FullName --dry-run --stats-out $STATS
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Die "dry-run 失敗（exit $rc）" 242 }
if (-not (Test-Path $STATS)) { Die 'dry-run 沒有產出 stats.json' 242 }

$s = Get-Content $STATS -Raw -Encoding UTF8 | ConvertFrom-Json
Say ("   爬蟲 {0} 筆｜現有 {1} 筆｜新物件 {2} 筆｜就地更新 {3} 筆" -f $s.crawl, $s.existing, $s.new, $s.updates)

if ($s.crawl   -lt $MIN_CRAWL)   { Die "爬蟲只有 $($s.crawl) 筆（門檻 $MIN_CRAWL）——資料不可信，不上架" 241 }
if ($s.new     -gt $MAX_NEW)     { Die "新物件 $($s.new) 筆超過門檻 $MAX_NEW——疑似案號比對壞掉" 241 }
if ($s.updates -gt $MAX_UPDATES) { Die "更新 $($s.updates) 筆超過門檻 $MAX_UPDATES——疑似案號比對壞掉" 241 }

if ($s.new -eq 0 -and $s.updates -eq 0) {
  Say '✅ 無異動（新物件 0 筆、更新 0 筆）'
  Invoke-Purge
  Push-Pending '無異動路徑'
  Stop-Transcript | Out-Null
  exit 0
}
if ($DryRun) {
  Say '✅ -DryRun：到此為止，沒有寫入任何檔案。'
  Push-Pending '-DryRun 路徑'
  Stop-Transcript | Out-Null
  exit 0
}

# ---------- 3. 實際上架 ----------
Say '3. publish_new.py（實際寫入）'
Push-Location $CRAWL_REPO
& $PY_CRAWL publish_new.py $json.FullName --stats-out $STATS
$rc = $LASTEXITCODE
Pop-Location
if ($rc -ne 0) { Die "上架失敗（exit $rc）" 242 }

$s2 = Get-Content $STATS -Raw -Encoding UTF8 | ConvertFrom-Json
$nAdd = @($s2.added).Count
$nUpd = @($s2.updated).Count
Say "   實際新增 $nAdd 筆、更新 $nUpd 筆"
if ($nAdd -ne $s.new -or $nUpd -ne $s.updates) {
  Die "實際筆數（$nAdd/$nUpd）與 dry-run（$($s.new)/$($s.updates)）不符" 242
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
GitLogged @('add', '-A')
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
# 不用 Set-Content -Encoding utf8：PowerShell 5.1 會寫入 BOM，commit 標題開頭就多一個看不見的字元
[IO.File]::WriteAllText($msgFile, $msg, (New-Object Text.UTF8Encoding $false))
GitLogged @('commit', '-q', '-F', $msgFile)
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
  if ($ahead -ne '0') { Die "還有 $ahead 個 commit 沒推上去" 242 }
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
  Die "有 $($missing.Count) 個檔案沒生成" 242
}

Invoke-Purge
Push-Pending '收尾'
Say "===== 完成：新增 $nAdd 筆、更新 $nUpd 筆、清除 $script:nPurge 筆 ====="
Stop-Transcript | Out-Null
exit 0
