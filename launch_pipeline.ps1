<#
.SYNOPSIS
    法拍上架產線的本機啟動器。放在 C:，由 Windows 工作排程器呼叫，再去叫 G: 上的 run_pipeline.ps1。

.DESCRIPTION
    為什麼需要它（2026-09-17）：
      9/16 的排程在 11:13:59 補跑（09:07 當下沒人登入，11:08 才登入），
      powershell.exe 啟動 run_pipeline.ps1 後**同一秒就結束，退出碼 0**，
      沒有 log、沒有爬蟲、沒有 commit——排程器回報成功，實際上什麼都沒做。
      最可能的原因是登入才 5 分鐘，Google Drive 已掛上 G: 但檔案內容尚未就緒，
      PowerShell 讀到空內容當成空腳本執行（實測 -File 指向不存在的路徑會回 -196608，
      不是 0，所以不是「找不到檔案」）。

    這支做兩件事，把「假成功」變成看得見的失敗：
      1. 開跑前：等到 G: 上的 run_pipeline.ps1 讀得到**完整內容**（最多 WaitMinutes 分鐘）
      2. 跑完後：確認這次**真的有產生 log**；退出碼 0 卻沒有 log → 回 4

    自己的紀錄寫在本機 %LOCALAPPDATA%\QueenOfAuctions\launcher-logs\，不依賴 G:。

    ⚠️ 正本在 repo（Queen-of-Auctions\launch_pipeline.ps1），排程執行的是 C: 上的複本。
       改了 repo 這份要重新複製過去，見 docs\新電腦設定.md。

.NOTES
    退出碼：沿用 run_pipeline.ps1 的 0～3，另加
      4  產線回報 0 但沒有產生 log（假成功）
      5  等了 WaitMinutes 分鐘，G: 上的腳本仍讀不到完整內容
#>
[CmdletBinding()]
param(
  [string] $PipelineScript = 'G:\我的雲端硬碟\ai agent\Queen-of-Auctions\run_pipeline.ps1',
  [int]    $WaitMinutes    = 20,
  [switch] $DryRun,
  [switch] $SkipCrawl,
  [switch] $NoPush
)

$ErrorActionPreference = 'Stop'

$LOCAL = Join-Path $env:LOCALAPPDATA 'QueenOfAuctions\launcher-logs'
if (-not (Test-Path $LOCAL)) { New-Item -ItemType Directory -Force $LOCAL | Out-Null }
$LLOG = Join-Path $LOCAL ((Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.log')

function L([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  [IO.File]::AppendAllText($LLOG, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
  Write-Host $line
}

L "啟動器開始｜目標 $PipelineScript｜最多等 $WaitMinutes 分鐘"

# ---------- 1. 等 G: 上的腳本讀得到完整內容 ----------
# 判斷「完整」：長度夠、而且讀得到 Start-Transcript（產線第一個會留下紀錄的動作）。
# 空檔、半檔、Drive 佔位檔都過不了這關。
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$ready = $false
while ($true) {
  try {
    if (Test-Path -LiteralPath $PipelineScript) {
      $txt = [IO.File]::ReadAllText($PipelineScript)
      if ($txt.Length -gt 2000 -and $txt.Contains('Start-Transcript')) { $ready = $true; break }
      L "腳本讀得到但內容不完整（$($txt.Length) 字元），等 Google Drive 就緒…"
    } else {
      L '找不到腳本（G: 可能尚未掛載），等待…'
    }
  } catch {
    L "讀取失敗：$($_.Exception.Message)，等待…"
  }
  if ((Get-Date) -ge $deadline) { break }
  Start-Sleep -Seconds 30
}
if (-not $ready) {
  L "❌ 等了 $WaitMinutes 分鐘仍讀不到完整腳本，放棄（exit 5）"
  exit 5
}
L "腳本就緒（$($txt.Length) 字元）"

# ---------- 2. 執行產線 ----------
$logDir = Join-Path (Split-Path -Parent $PipelineScript) 'output\pipeline-logs'
$t0 = Get-Date
$argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PipelineScript)
if ($DryRun)    { $argv += '-DryRun' }
if ($SkipCrawl) { $argv += '-SkipCrawl' }
if ($NoPush)    { $argv += '-NoPush' }
L ('執行：powershell ' + ($argv -join ' '))
& powershell.exe @argv
$rc = $LASTEXITCODE
L "產線結束，退出碼 $rc，耗時 $([int]((Get-Date) - $t0).TotalMinutes) 分鐘"

# ---------- 3. 確認真的有跑：這次的 log 在不在 ----------
# G: 是 Google Drive，剛寫入的檔案偶爾要等一下才列得出來，給 60 秒。
$newLog = $null
for ($i = 0; $i -lt 12 -and -not $newLog; $i++) {
  if (Test-Path -LiteralPath $logDir) {
    $newLog = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-5) } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if (-not $newLog) { Start-Sleep -Seconds 5 }
}

if (-not $newLog) {
  if ($rc -eq 0) {
    L '❌ 產線回報 0，但沒有產生任何 log——假成功（exit 4）'
    exit 4
  }
  L "⚠ 沒有找到 log，沿用產線退出碼 $rc"
  exit $rc
}

L "產線 log：$($newLog.FullName)"
exit $rc
