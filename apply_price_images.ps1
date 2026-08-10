<#
  apply_price_images.ps1 — 把網頁改指向 burn_price.ps1 產生的燒價圖

  1) 104woo.html 的 BASE_ITEMS：每筆補上
       "thumb":"wNNN/card.jpg"   總覽卡片用（方案 A 右下角價格牌）
       "hero" :"wNNN/hero.jpg"   頁內詳細頁用（方案 B 底部漸層大字）
  2) 每個 wNNN/index.html：
       <img class="prop" src="photo.jpg|map.jpg">  ->  hero.jpg
       og:image 的 photo.jpg|map.jpg               ->  hero.jpg

  只有在 card.jpg / hero.jpg 真的存在時才改，已改過的會跳過（可重複執行）。
  還原方式：git checkout -- 104woo.html "w*/index.html"

  注意：本檔含中文，必須存成「UTF-8 with BOM」，否則 PowerShell 5.1 會用 ANSI 讀而解析失敗。

  用法：
    powershell -File apply_price_images.ps1 -WhatIf   # 只報告不寫檔
    powershell -File apply_price_images.ps1
#>
[CmdletBinding()]
param(
  [switch]$WhatIf,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }

# 專案的 html 都是「UTF-8 無 BOM + CRLF」，寫回時要保持一致
$UTF8_NOBOM = New-Object System.Text.UTF8Encoding($false)
function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $UTF8_NOBOM) }

# ===== 1) 104woo.html：BASE_ITEMS 補 thumb / hero =====
$htmlPath = Join-Path $Root '104woo.html'
$html = Read-Text $htmlPath
$before = $html

# 前面限定 , 或 { ，避免誤中 "mapimg":" 之類以 img 結尾的欄位名。
# 一併吃掉既有的 thumb／hero 再重寫，這樣重複執行不會插出重複的 JSON key。
$pattern = '([,{])(?:"thumb":"w\d+/card\.jpg",)?(?:"hero":"w\d+/hero\.jpg",)?"img":"(w\d+)/(photo|map)\.jpg"'
$added = 0
$html = [regex]::Replace($html, $pattern, {
  param($m)
  $code = $m.Groups[2].Value
  $file = $m.Groups[3].Value
  $dir = Join-Path $Root $code
  # 衍生圖不存在就原樣保留，不要指向不存在的檔
  if (-not (Test-Path (Join-Path $dir 'card.jpg')) -or -not (Test-Path (Join-Path $dir 'hero.jpg'))) {
    return $m.Value
  }
  $script:added++
  '{0}"thumb":"{1}/card.jpg","hero":"{1}/hero.jpg","img":"{1}/{2}.jpg"' -f $m.Groups[1].Value, $code, $file
})

if ($added -gt 0 -and -not $WhatIf) { Write-Text $htmlPath $html }
$state = if ($WhatIf) { '（WhatIf，未寫檔）' } else { '' }
if ($before -eq $html) { Write-Host "104woo.html：無需變更（可能已套用過）" }
else { Write-Host ("104woo.html：{0} 筆補上 thumb + hero {1}" -f $added, $state) }

# ===== 2) 每個 wNNN/index.html =====
$dirs = Get-ChildItem $Root -Directory | Where-Object { $_.Name -match '^w\d+$' } | Sort-Object Name
$changed = 0; $skipped = 0; $noHero = 0

foreach ($d in $dirs) {
  $idx = Join-Path $d.FullName 'index.html'
  if (-not (Test-Path $idx)) { continue }
  if (-not (Test-Path (Join-Path $d.FullName 'hero.jpg'))) { $noHero++; continue }

  $t = Read-Text $idx
  $orig = $t
  $t = [regex]::Replace($t, '(<img class="prop" src=")(?:photo|map)\.jpg(")', '${1}hero.jpg${2}')
  $t = [regex]::Replace($t, '(og:image" content="[^"]*/w\d+/)(?:photo|map)\.jpg(")', '${1}hero.jpg${2}')

  if ($t -eq $orig) { $skipped++; continue }
  if (-not $WhatIf) { Write-Text $idx $t }
  $changed++
}

Write-Host ("物件頁：{0} 個已改指向 hero.jpg {1}" -f $changed, $state)
if ($skipped -gt 0) { Write-Host ("　　　　{0} 個無需變更（已套用過）" -f $skipped) }
if ($noHero  -gt 0) { Write-Host ("　　　　{0} 個跳過（還沒有 hero.jpg）" -f $noHero) }
