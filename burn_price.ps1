<#
  burn_price.ps1 — 把「拍賣底價」燒進物件圖片

  對每一筆物件，從原始底圖（photo.jpg，無則 map.jpg）產生兩個衍生檔：
    card.jpg  660x340   方案 A：右下角深藍價格牌（總覽卡片用）
    hero.jpg  1422x840  方案 B：底部漸層大字（物件頁大圖 + og:image）

  原始底圖不會被改動，所以本腳本可重複執行、可隨時刪掉衍生檔還原。
  價格資料源：104woo.html 的 BASE_ITEMS（單一真理源）。

  注意：本檔含中文，必須存成「UTF-8 with BOM」，否則 PowerShell 5.1 會用 ANSI 讀而解析失敗。
        若用編輯器改過而中文變亂碼，重新以 UTF-8 BOM 另存即可。

  用法：
    powershell -File burn_price.ps1 -Only w400,w404,w405   # 先試幾筆
    powershell -File burn_price.ps1                        # 全部（跳過已存在）
    powershell -File burn_price.ps1 -Force                 # 全部重做
#>
[CmdletBinding()]
param(
  [string[]]$Only = @(),
  [switch]$Force,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }

# 用 powershell -File 呼叫時，-Only w400,w404 會整串當成一個字串傳進來，這裡統一拆開
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Add-Type -AssemblyName System.Drawing

# ===== 版面常數（對應 104woo.html / wNNN/index.html 的實際顯示比例）=====
$CARD_W = 660;  $CARD_H = 340     # 卡片 330x170 的 2 倍
$HERO_W = 1422; $HERO_H = 840     # 物件頁 948x560 的 1.5 倍
$FONT_FAMILY = 'Microsoft JhengHei'

$BRAND = [System.Drawing.Color]::FromArgb(237,   0,  74, 173)  # #004AAD 93%
$GOLD  = [System.Drawing.Color]::FromArgb(255, 255, 211,  92)  # #FFD35C
$WHITE = [System.Drawing.Color]::White
$LBLUE = [System.Drawing.Color]::FromArgb(255, 207, 224, 247)  # #CFE0F7
$LGREY = [System.Drawing.Color]::FromArgb(255, 227, 231, 234)  # #E3E7EA

# GenericTypographic：去掉 GDI+ 預設的額外邊距，量出來才貼合實際字寬
[System.Drawing.StringFormat]$TYPO = [System.Drawing.StringFormat]::GenericTypographic.Clone()

# ===== 工具函式 =====

function Get-Prop($Obj, [string]$Name) {
  if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
  return $null
}

function New-Font([single]$Size) {
  New-Object System.Drawing.Font -ArgumentList $FONT_FAMILY, $Size,
    ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
}

function Measure-Text([System.Drawing.Graphics]$G, [string]$Text, [System.Drawing.Font]$Font) {
  return $G.MeasureString($Text, $Font, [System.Drawing.PointF]::new(0, 0), $TYPO).Width
}

function Draw-Text([System.Drawing.Graphics]$G, [string]$Text, [System.Drawing.Font]$Font,
                   [System.Drawing.Color]$Color, [single]$X, [single]$Y) {
  $b = New-Object System.Drawing.SolidBrush -ArgumentList $Color
  $G.DrawString($Text, $Font, $b, [System.Drawing.PointF]::new($X, $Y), $TYPO)
  $b.Dispose()
}

# GDI+ 沒有 letter-spacing，逐字畫出字間距
function Measure-Tracked([System.Drawing.Graphics]$G, [string]$Text, [System.Drawing.Font]$Font, [single]$Track) {
  $w = 0
  foreach ($ch in $Text.ToCharArray()) { $w += (Measure-Text $G "$ch" $Font) + $Track }
  return ($w - $Track)
}

function Draw-Tracked([System.Drawing.Graphics]$G, [string]$Text, [System.Drawing.Font]$Font,
                      [System.Drawing.Color]$Color, [single]$X, [single]$Y, [single]$Track) {
  $cx = $X
  foreach ($ch in $Text.ToCharArray()) {
    Draw-Text $G "$ch" $Font $Color $cx $Y
    $cx += (Measure-Text $G "$ch" $Font) + $Track
  }
}

# GDI+ 沒有陰影模糊，用多層半透明黑位移模擬 CSS text-shadow
function Draw-Shadowed([System.Drawing.Graphics]$G, [string]$Text, [System.Drawing.Font]$Font,
                       [System.Drawing.Color]$Color, [single]$X, [single]$Y, [single]$Blur) {
  $dark = [System.Drawing.Color]::FromArgb(105, 0, 0, 0)
  foreach ($d in @(@($Blur, $Blur), @(0, $Blur), @($Blur, 0), @(0, 0))) {
    Draw-Text $G $Text $Font $dark ($X + $d[0]) ($Y + $d[1])
  }
  Draw-Text $G $Text $Font $Color $X $Y
}

function New-RoundedPath([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $R * 2
  $p.AddArc($X,           $Y,           $d, $d, 180, 90)
  $p.AddArc($X + $W - $d, $Y,           $d, $d, 270, 90)
  $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
  $p.AddArc($X,           $Y + $H - $d, $d, $d,  90, 90)
  $p.CloseFigure()
  return $p
}

# 縮放並置中裁切成指定尺寸（等同 CSS object-fit:cover）
function New-CoverBitmap([System.Drawing.Image]$Src, [int]$W, [int]$H) {
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $W, $H
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $scale = [Math]::Max($W / $Src.Width, $H / $Src.Height)
  $dw = $Src.Width * $scale
  $dh = $Src.Height * $scale
  $g.DrawImage($Src, [single](($W - $dw) / 2), [single](($H - $dh) / 2), [single]$dw, [single]$dh)
  $g.Dispose()
  return $bmp
}

function Save-Jpeg([System.Drawing.Bitmap]$Bmp, [string]$Path, [int]$Quality) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ps = New-Object System.Drawing.Imaging.EncoderParameters -ArgumentList 1
  $ps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter -ArgumentList ([System.Drawing.Imaging.Encoder]::Quality), ([int64]$Quality)
  $Bmp.Save($Path, $codec, $ps)
  $ps.Dispose()
}

# 1821.0 -> "1,821"；123.1 -> "123.1"
function Format-Price($P) {
  if ($null -eq $P -or "$P" -eq '') { return $null }
  $n = [double]$P
  if ([Math]::Abs($n - [Math]::Round($n)) -lt 0.05) { return ([int][Math]::Round($n)).ToString('N0') }
  return $n.ToString('N1')
}

# ===== 方案 A：右下角價格牌 =====
function Draw-BadgeA([System.Drawing.Graphics]$G, [int]$W, [int]$H, [string]$Price) {
  # card.jpg 是 660 寬，卡片最窄時（330px）以 0.5 倍顯示，
  # 所以圖檔內 48px = 畫面上 24px。標籤與「萬」等比例縮放。
  $fLb  = New-Font 17
  $fNum = New-Font 48
  $fU   = New-Font 23
  try {
    $track = 2.5
    $padX = 20.0; $padTop = 13.0; $padBot = 14.0; $gapLbNum = 6.0; $gapNU = 5.0; $margin = 16.0

    $wLb  = Measure-Tracked $G '拍賣底價' $fLb $track
    $wNum = Measure-Text $G $Price $fNum
    $wU   = Measure-Text $G '萬' $fU

    # 由文字位置反推方框大小，避免字爆出圓角框外
    $offLb  = $padTop
    $offNum = $offLb + $fLb.Height + $gapLbNum
    $boxH   = $offNum + $fNum.Height + $padBot
    $boxW   = [Math]::Max($wLb, $wNum + $gapNU + $wU) + $padX * 2
    $boxX   = $W - $margin - $boxW
    $boxY   = $H - $margin - $boxH

    $sPath = New-RoundedPath ($boxX + 3) ($boxY + 4) $boxW $boxH 13
    $shadow = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
    $G.FillPath($shadow, $sPath)
    $path = New-RoundedPath $boxX $boxY $boxW $boxH 13
    $brush = New-Object System.Drawing.SolidBrush -ArgumentList $BRAND
    $G.FillPath($brush, $path)

    # 標籤與數字都靠右對齊
    $rx = $boxX + $boxW - $padX
    Draw-Tracked $G '拍賣底價' $fLb $LBLUE ($rx - $wLb) ($boxY + $offLb) $track
    $numY = $boxY + $offNum
    Draw-Text $G '萬'   $fU   $WHITE ($rx - $wU) ($numY + $fNum.Height - $fU.Height)
    Draw-Text $G $Price $fNum $GOLD  ($rx - $wU - $gapNU - $wNum) $numY

    $shadow.Dispose(); $brush.Dispose(); $path.Dispose(); $sPath.Dispose()
  } finally { $fLb.Dispose(); $fNum.Dispose(); $fU.Dispose() }
}

# ===== 方案 B：底部漸層大字（靠右，避開左下角的慧瑜人像）=====
function Draw-BandB([System.Drawing.Graphics]$G, [int]$W, [int]$H, [string]$Price, [string]$Sub) {
  # 逐列自己算 alpha。GDI+ 的 LinearGradientBrush 不照 ColorBlend 的 Positions 走，
  # 會壓得比預期黑很多；這裡直接線性內插三個色停，對齊 CSS：
  #   transparent -> rgba(0,0,0,.50) @58% -> rgba(0,0,0,.82) @100%
  $bandH = [int]($H * 0.42)
  $top = $H - $bandH
  for ($y = 0; $y -lt $bandH; $y++) {
    $t = $y / [double]($bandH - 1)
    $a = if ($t -le 0.58) { 128 * ($t / 0.58) } else { 128 + (209 - 128) * (($t - 0.58) / 0.42) }
    $br = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb([int]$a, 0, 0, 0))
    $G.FillRectangle($br, 0, ($top + $y), $W, 1)
    $br.Dispose()
  }

  $fLb  = New-Font 26
  $fNum = New-Font 108
  $fU   = New-Font 42
  $fSub = New-Font 26
  try {
    $track = 4.0; $margin = 34.0; $gapNU = 8.0
    $rx = $W - $margin

    # 由下往上排：副標 -> 數字 -> 標籤
    $subY = $H - $margin - $fSub.Height
    if ($Sub) { Draw-Shadowed $G $Sub $fSub $LGREY ($rx - (Measure-Text $G $Sub $fSub)) $subY 2 }

    $wNum = Measure-Text $G $Price $fNum
    $wU   = Measure-Text $G '萬' $fU
    $numY = $subY - $fNum.Height + 6
    Draw-Shadowed $G '萬'   $fU   $WHITE ($rx - $wU) ($numY + $fNum.Height - $fU.Height) 3
    Draw-Shadowed $G $Price $fNum $WHITE ($rx - $wU - $gapNU - $wNum) $numY 3

    $wLb = Measure-Tracked $G '拍賣底價' $fLb $track
    Draw-Tracked $G '拍賣底價' $fLb $LGREY ($rx - $wLb) ($numY - $fLb.Height + 4) $track
  } finally { $fLb.Dispose(); $fNum.Dispose(); $fU.Dispose(); $fSub.Dispose() }
}

# ===== 讀 BASE_ITEMS =====
$htmlPath = Join-Path $Root '104woo.html'
if (-not (Test-Path $htmlPath)) { throw "找不到 104woo.html：$htmlPath" }

$html = Get-Content $htmlPath -Raw -Encoding UTF8
# BASE_ITEMS 全部擠在同一行，所以不開 Singleline、用貪婪比對抓到該行最後一個 ]
$m = [regex]::Match($html, 'const\s+BASE_ITEMS\s*=\s*(\[.*\])\s*;')
if (-not $m.Success) { throw '104woo.html 裡找不到 BASE_ITEMS' }
# 注意：PowerShell 5.1 的 ConvertFrom-Json 會把整個陣列當「一個物件」丟出，
# 必須先接成變數再 @() 展開，否則 Count 會是 1。
$parsed = ConvertFrom-Json -InputObject $m.Groups[1].Value
$items = @($parsed)
Write-Host ("BASE_ITEMS 讀到 {0} 筆" -f $items.Count)

if ($Only.Count -gt 0) {
  $items = @($items | Where-Object { $Only -contains (Get-Prop $_ 'code') })
  Write-Host ("指定處理 {0} 筆：{1}" -f $items.Count, ($Only -join ', '))
}

# ===== 主迴圈 =====
$done = 0; $skipped = 0; $noSrc = 0; $noPrice = 0
foreach ($it in $items) {
  $code = Get-Prop $it 'code'
  if (-not $code) { continue }
  $dir = Join-Path $Root $code
  if (-not (Test-Path $dir)) { continue }

  $price = Format-Price (Get-Prop $it 'price')
  if (-not $price) { $noPrice++; continue }

  $src = Join-Path $dir 'photo.jpg'
  if (-not (Test-Path $src)) { $src = Join-Path $dir 'map.jpg' }
  if (-not (Test-Path $src)) { $noSrc++; continue }

  $cardOut = Join-Path $dir 'card.jpg'
  $heroOut = Join-Path $dir 'hero.jpg'
  if (-not $Force -and (Test-Path $cardOut) -and (Test-Path $heroOut)) { $skipped++; continue }

  $unit = Get-Prop $it 'unit'
  $sub = if ($null -ne $unit -and "$unit" -ne '') { "單價 $unit 萬/坪" } else { '' }

  $img = [System.Drawing.Image]::FromFile($src)
  try {
    foreach ($job in @(
      @{ Out = $cardOut; W = $CARD_W; H = $CARD_H; Style = 'A'; Q = 82 },
      @{ Out = $heroOut; W = $HERO_W; H = $HERO_H; Style = 'B'; Q = 84 }
    )) {
      $bmp = New-CoverBitmap $img $job.W $job.H
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
      if ($job.Style -eq 'A') { Draw-BadgeA $g $job.W $job.H $price }
      else                    { Draw-BandB  $g $job.W $job.H $price $sub }
      $g.Dispose()
      Save-Jpeg $bmp $job.Out $job.Q
      $bmp.Dispose()
    }
  } finally { $img.Dispose() }

  $done++
  if ($done % 25 -eq 0) { Write-Host ("  已完成 {0} 筆…" -f $done) }
}

Write-Host ''
Write-Host ("完成：{0} 筆已生成 card.jpg + hero.jpg" -f $done)
if ($skipped -gt 0) { Write-Host ("略過（已存在，可用 -Force 重做）：{0} 筆" -f $skipped) }
if ($noSrc   -gt 0) { Write-Host ("略過（無底圖）：{0} 筆" -f $noSrc) }
if ($noPrice -gt 0) { Write-Host ("略過（無底價）：{0} 筆" -f $noPrice) }
