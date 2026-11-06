# Generates the Nowhere SHUTDOWN animation: the mirror of the boot logo. Starts on the fully lit gate
# SporeView cluster, then winds down -- the six points dim out one at a time in REVERSE ignition order (the
# bottom teal core is the last light to go), and the wordmark dims to grey and out, ending dark. NO
# CONNECTING LINES (D5, NWP-20260823-02) -- same rule as the boot animation: the gate's linkless SporeView is
# the canonical mark. Plays ONCE at power-off (desc: `p 1 0 part0`). Same gate geometry + two brand colors as
# make-bootanimation.ps1. Offline; .NET GDI+. STORED zip entries (bootanimation mmaps each frame).
param(
  [int]$Width  = 1080,
  [int]$Height = 2160,
  [int]$FPS    = 12,
  [string]$Wordmark = 'diaspore',
  [string]$OutDir = (Join-Path $PSScriptRoot 'media')
)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$W = $Width; $H = $Height
$cx = [double]($W / 2.0); $ccy = [double]($H * 0.40)

# EXACT gate SporeView geometry (66x34 space, y down): x, y, radius, color, base brightness (= gate alpha/255).
$GX = @(33, 22, 44, 14, 52, 34)
$GY = @(27, 18, 16,  9,  8,  5)
$GR = @(4.2, 2.6, 3.0, 2.0, 2.0, 1.6)
$GCR = @( 79, 234,  79,  79, 234,  79)
$GCG = @(214, 241, 214, 214, 241, 214)
$GCB = @(172, 238, 172, 172, 238, 172)
$GB = @(1.00, 0.90, 0.78, 0.64, 0.58, 0.60)
$CXG = 33; $CYG = 16
$N = 6
$RING = @(0, 2, 4, 5, 3, 1)
$ringPos = New-Object 'int[]' $N
for ($i = 0; $i -lt $N; $i++) { $ringPos[$RING[$i]] = $i }

# Wind-down timing: a brief lit hold, then dim the points out in REVERSE ignition order (dimPos = N-1-ringPos,
# so the first-lit bottom core dims last). Links fade early; the wordmark dims to grey across the whole thing.
$HOLD = 0.35; $STAGGER = 0.28; $DIM_DUR = 0.55
$WORD_A = 0.5; $WORD_B = 2.4
$DUR = 2.7
$P0 = [int][Math]::Round($DUR * $FPS)

$clusterW = [Math]::Min($W * 0.74, $H * 0.40)
$S = $clusterW / 66.0
$dx = New-Object 'double[]' $N; $dy = New-Object 'double[]' $N
$dcr = New-Object 'double[]' $N; $ddim = New-Object 'double[]' $N
$spread = 1.10                        # match make-bootanimation: nudge the points apart so glows never touch
for ($i = 0; $i -lt $N; $i++) {
  $dx[$i] = $cx + ($GX[$i] - $CXG) * $S * $spread
  $dy[$i] = $ccy + ($GY[$i] - $CYG) * $S * $spread
  $dcr[$i] = $GR[$i] * $S
  $ddim[$i] = $HOLD + ($N - 1 - $ringPos[$i]) * $STAGGER
}

$bg = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
$font    = New-Object System.Drawing.Font('Segoe UI', [single]($W * 0.125), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$subFont = New-Object System.Drawing.Font('Segoe UI', [single]($W * 0.045), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center

function Clamp01([double]$v) { if ($v -lt 0) { return 0.0 } elseif ($v -gt 1) { return 1.0 } else { return $v } }
function Smooth([double]$a, [double]$b, [double]$x) { $t = Clamp01(($x - $a) / ($b - $a)); return $t * $t * (3 - 2 * $t) }
function A255([double]$a) { $v = [int][Math]::Round($a * 255); if ($v -lt 0) { return 0 } elseif ($v -gt 255) { return 255 } else { return $v } }

function DrawRadial($g, [double]$x, [double]$y, [double]$rad, [int]$cr, [int]$cg, [int]$cb, [int]$ca) {
  if ($ca -le 1 -or $rad -le 0.5) { return }
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddEllipse([single]($x - $rad), [single]($y - $rad), [single]($rad * 2), [single]($rad * 2))
  $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
  $pgb.CenterColor = [System.Drawing.Color]::FromArgb($ca, $cr, $cg, $cb)
  $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $cr, $cg, $cb))
  $g.FillPath($pgb, $path)
  $pgb.Dispose(); $path.Dispose()
}
function Glow($g, [double]$x, [double]$y, [double]$rad, [int]$r, [int]$gg, [int]$b, [double]$a) { DrawRadial $g $x $y $rad $r $gg $b (A255 $a) }
function CoreDot($g, [double]$x, [double]$y, [double]$rad, [int]$r, [int]$gg, [int]$b, [double]$a) {
  $ai = A255 $a
  DrawRadial $g $x $y $rad $r $gg $b ([int]($ai * 0.9))
  DrawRadial $g $x $y ($rad * 0.46) 255 255 255 $ai
}
function DrawDot($g, [int]$i, [double]$amp) {
  if ($amp -le 0.004) { return }
  Glow $g $dx[$i] $dy[$i] ($dcr[$i] * 1.7) $GCR[$i] $GCG[$i] $GCB[$i] (0.32 * $amp)
  Glow $g $dx[$i] $dy[$i] ($dcr[$i] * 1.15) $GCR[$i] $GCG[$i] $GCB[$i] (0.58 * $amp)
  $ca = $amp * 1.12; if ($ca -gt 1) { $ca = 1 }
  CoreDot $g $dx[$i] $dy[$i] ($dcr[$i] * 0.85) $GCR[$i] $GCG[$i] $GCB[$i] $ca
}
# Wordmark + tagline dimming to grey (alpha multiplier). Drawn under the glow (source-over).
function DrawText($g, [double]$wf) {
  if ($wf -le 0.01) { return }
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb((A255 (0.95 * $wf)), 246, 250, 255))
  $g.DrawString($Wordmark, $font, $tb, [single]$cx, [single]($H * 0.605), $sf); $tb.Dispose()
  $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb((A255 (0.78 * $wf)), 150, 176, 200))
  $g.DrawString('your phone, nowhere', $subFont, $sb, [single]$cx, [single]($H * 0.685), $sf); $sb.Dispose()
}

$work = Join-Path $env:TEMP ('shutanim_' + [Guid]::NewGuid().ToString('N'))
$part0 = Join-Path $work 'part0'
[IO.Directory]::CreateDirectory($part0) | Out-Null
[IO.Directory]::CreateDirectory($OutDir) | Out-Null

for ($f = 0; $f -lt $P0; $f++) {
  $t = $f / [double]$FPS
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear($bg)

  DrawText $g (1 - (Smooth $WORD_A $WORD_B $t))
  Glow $g $cx $ccy ($S * 30) 26 120 150 (0.06 * (1 - (Smooth 0.3 2.0 $t)))

  for ($i = 0; $i -lt $N; $i++) {
    $dim = 1 - (Smooth $ddim[$i] ($ddim[$i] + $DIM_DUR) $t)
    DrawDot $g $i ($dim * $GB[$i])
  }

  $g.Dispose()
  $bmp.Save((Join-Path $part0 ('frame{0:0000}.png' -f $f)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# play the wind-down ONCE (count=1), then bootanimation holds the last (black) frame until power cuts.
[IO.File]::WriteAllText((Join-Path $work 'desc.txt'), "$W $H $FPS`np 1 0 part0`n")

$zipPath = Join-Path $OutDir 'shutdownanimation.zip'
if (Test-Path $zipPath) { [IO.File]::Delete($zipPath) }
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-Stored($zip, $file, $name) {
  $e = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::NoCompression)
  $s = $e.Open(); $bytes = [IO.File]::ReadAllBytes($file); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
}
Add-Stored $zip (Join-Path $work 'desc.txt') 'desc.txt'
[IO.Directory]::GetFiles($part0, '*.png') | Sort-Object | ForEach-Object { Add-Stored $zip $_ ('part0/' + [IO.Path]::GetFileName($_)) }
$zip.Dispose()
[IO.Directory]::Delete($work, $true)
Write-Output ("shutdownanimation.zip: " + (Get-Item $zipPath).Length + " bytes; $P0 frames @ ${FPS}fps; ${W}x${H}")
