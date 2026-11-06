# Generates the Nowhere boot animation: the GATE LOGO cluster (the six SporeView points, exact geometry +
# the two brand colors + the same size/brightness hierarchy) igniting in a slow wave around the ring, then a
# slow bead of light drifting point to point -- with the "diaspore / your phone, nowhere" wordmark on the
# whole time. NO CONNECTING LINES (D5, NWP-20260823-02): the gate's SporeView draws six plain points and is
# the CANONICAL mark; the animation used to add a linked ring the mark itself never had, and Chester's
# standing backlog row asked for the line's removal. The ring ORDER survives as the ignition/bead PATH -- a
# moving light needs no drawn track.
#   part0 = intro (staggered ignition wave + settle), played ONCE
#   part1 = steady state (gentle breathing + one slow bead lap), LOOPED until boot ends
# The six points ARE the brand mark, so this is edition-neutral; -OutDir retargets the output. Offline; GDI+.
# NOTE: Android's bootanimation mmaps each frame, so the zip entries MUST be STORED (method 0). .NET's
# CompressionLevel.NoCompression emits STORED (method 0) ONLY under .NET Core -- i.e. run this with `pwsh`
# (PowerShell 7). Windows PowerShell 5.1 (.NET Framework) encodes NoCompression as DEFLATE (method 8), which
# the FP3 bootanimation player CANNOT display -> a BLANK boot screen (fairphone logo straight to the gate).
# ALWAYS generate with pwsh; verify with: python -c "import zipfile;print({i.compress_type for i in zipfile.ZipFile('bootanimation.zip').infolist()})" == {0}.
# Rendered at NATIVE 1080x2160 so the wordmark + bright cores are crisp (a lower res upscales blurry).
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
# Two colors only: teal #4FD6AC (79,214,172) and off-white #EAF1EE (234,241,238). Bottom point is biggest +
# brightest; points fan up and dim toward the top -- the gate's own hierarchy.
$GX = @(33, 22, 44, 14, 52, 34)
$GY = @(27, 18, 16,  9,  8,  5)
$GR = @(4.2, 2.6, 3.0, 2.0, 2.0, 1.6)
$GCR = @( 79, 234,  79,  79, 234,  79)
$GCG = @(214, 241, 214, 214, 241, 214)
$GCB = @(172, 238, 172, 172, 238, 172)
$GB = @(1.00, 0.90, 0.78, 0.64, 0.58, 0.60)
$CXG = 33; $CYG = 16
$N = 6
$RING = @(0, 2, 4, 5, 3, 1)          # closed convex ring: bottom -> right -> up-right -> top -> up-left -> left
$ringPos = New-Object 'int[]' $N
for ($i = 0; $i -lt $N; $i++) { $ringPos[$RING[$i]] = $i }
$breathCyc = @(1, 2, 1, 2, 1, 1)     # integer breaths per lap => the loop stays seamless

# Slow formation so the ignition wave reads clearly (each point ~0.55s after the previous, around the ring).
$IGNITE0 = 0.6; $STAGGER = 0.55; $SETTLE = 0.7
# T0 once had to outlast the links' draw-on (removed in D5); it is KEPT at 4.7 deliberately -- the last
# point settles at 3.35+0.7=4.05 and the ~0.65s hold lets the completed cluster register before the loop.
# Changing the intro length would also change every frame count downstream for no user-visible reason.
$T0 = 4.7; $CIRCUIT = 4.5            # intro seconds; loop-lap seconds (slow bead)
$P0 = [int][Math]::Round($T0 * $FPS)
$P1 = [int][Math]::Round($CIRCUIT * $FPS)

# Layout (matches the approved preview ratios): cluster centered high, wordmark + tagline below it.
$clusterW = [Math]::Min($W * 0.74, $H * 0.40)
$S = $clusterW / 66.0
$dx = New-Object 'double[]' $N; $dy = New-Object 'double[]' $N
$dcr = New-Object 'double[]' $N; $dign = New-Object 'double[]' $N
$spread = 1.10                        # nudge the points apart so the (brighter) glows never touch
for ($i = 0; $i -lt $N; $i++) {
  $dx[$i] = $cx + ($GX[$i] - $CXG) * $S * $spread
  $dy[$i] = $ccy + ($GY[$i] - $CYG) * $S * $spread
  $dcr[$i] = $GR[$i] * $S
  $dign[$i] = $IGNITE0 + $ringPos[$i] * $STAGGER
}

$bg = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
$font    = New-Object System.Drawing.Font('Segoe UI', [single]($W * 0.125), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$subFont = New-Object System.Drawing.Font('Segoe UI', [single]($W * 0.045), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center

function Clamp01([double]$v) { if ($v -lt 0) { return 0.0 } elseif ($v -gt 1) { return 1.0 } else { return $v } }
function Smooth([double]$a, [double]$b, [double]$x) { $t = Clamp01(($x - $a) / ($b - $a)); return $t * $t * (3 - 2 * $t) }
function EaseOut([double]$t) { return 1 - [Math]::Pow(1 - $t, 3) }
function EaseInOut([double]$t) { if ($t -lt 0.5) { return 4 * $t * $t * $t } else { return 1 - [Math]::Pow(-2 * $t + 2, 3) / 2 } }
function Lerp([double]$a, [double]$b, [double]$t) { return $a + ($b - $a) * $t }
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
  DrawRadial $g $x $y $rad $r $gg $b ([int]($ai * 0.9))          # colored blob
  DrawRadial $g $x $y ($rad * 0.46) 255 255 255 $ai            # white-hot center (crisp)
}
# One gate point: crisp core + light halo, at the gate's brightness. spike = ignition flash; lb = bead boost.
function DrawDot($g, [int]$i, [double]$vis, [double]$breath, [double]$spike, [double]$lb) {
  $amp = $vis * $GB[$i] * ($breath + $spike + $lb * 0.6)
  if ($amp -le 0.002) { return }
  Glow $g $dx[$i] $dy[$i] ($dcr[$i] * 1.7) $GCR[$i] $GCG[$i] $GCB[$i] (0.32 * $amp)
  Glow $g $dx[$i] $dy[$i] ($dcr[$i] * 1.15) $GCR[$i] $GCG[$i] $GCB[$i] (0.58 * $amp)
  $ca = $amp * 1.12; if ($ca -gt 1) { $ca = 1 }
  CoreDot $g $dx[$i] $dy[$i] ($dcr[$i] * 0.85) $GCR[$i] $GCG[$i] $GCB[$i] $ca
}
function DrawText($g) {
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
  $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(248, 246, 250, 255))
  $g.DrawString($Wordmark, $font, $tb, [single]$cx, [single]($H * 0.605), $sf); $tb.Dispose()
  $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(204, 150, 176, 200))
  $g.DrawString('your phone, nowhere', $subFont, $sb, [single]$cx, [single]($H * 0.685), $sf); $sb.Dispose()
}
$work = Join-Path $env:TEMP ('bootanim_' + [Guid]::NewGuid().ToString('N'))
$part0 = Join-Path $work 'part0'; $part1 = Join-Path $work 'part1'
[IO.Directory]::CreateDirectory($part0) | Out-Null
[IO.Directory]::CreateDirectory($part1) | Out-Null
[IO.Directory]::CreateDirectory($OutDir) | Out-Null

function NewFrame {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear($bg)
  return @($bmp, $g)
}

# ---- PART 0: intro (slow ignition wave -> links draw on -> settle; no bead yet) ----
for ($f = 0; $f -lt $P0; $f++) {
  $t = $f / [double]$FPS
  $fr = NewFrame; $bmp = $fr[0]; $g = $fr[1]
  DrawText $g
  $energy = Smooth 0.4 3.6 $t
  Glow $g $cx $ccy ($S * 30) 26 120 150 (0.06 * $energy)
  for ($i = 0; $i -lt $N; $i++) {
    $vis = Smooth ($dign[$i] - 0.02) ($dign[$i] + $SETTLE) $t
    if ($vis -le 0.001) { continue }
    $dtIg = $t - $dign[$i]
    $spike = if ($dtIg -gt 0) { [Math]::Exp(-$dtIg / 0.30) * 0.8 } else { 0 }
    DrawDot $g $i $vis 1.0 $spike 0.0
    if ($dtIg -gt 0 -and $dtIg -lt 0.85) {
      $rp = $dtIg / 0.85
      $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb((A255 ((1 - $rp) * 0.45)), $GCR[$i], $GCG[$i], $GCB[$i]), [single](1.3 * (1 - $rp) + 0.3))
      $r = $dcr[$i] * (1 + $rp * 1.8)
      $g.DrawEllipse($pen, [single]($dx[$i] - $r), [single]($dy[$i] - $r), [single]($r * 2), [single]($r * 2))
      $pen.Dispose()
    }
  }
  $g.Dispose()
  $bmp.Save((Join-Path $part0 ('frame{0:0000}.png' -f $f)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# ---- PART 1: steady state (persistent links + gentle breathing + one slow bead lap), seamless ----
for ($f = 0; $f -lt $P1; $f++) {
  $u = $f / [double]$P1
  $fr = NewFrame; $bmp = $fr[0]; $g = $fr[1]
  DrawText $g
  Glow $g $cx $ccy ($S * 30) 26 120 150 0.06

  # slow bead gliding point to point along the ring PATH (D5: the drawn links + the brighter active
  # segment are gone; the bead is a LIGHT, not a line, and carries the motion on its own)
  $sIdx = [int][Math]::Floor($u * $N); if ($sIdx -ge $N) { $sIdx = $N - 1 }
  $frac = $u * $N - $sIdx
  $ia = $RING[$sIdx]; $ib = $RING[($sIdx + 1) % $N]
  $fe = EaseInOut $frac
  $px = Lerp $dx[$ia] $dx[$ib] $fe; $py = Lerp $dy[$ia] $dy[$ib] $fe
  Glow $g $px $py ($S * 2.4) $GCR[$ia] $GCG[$ia] $GCB[$ia] 0.5
  CoreDot $g $px $py ($S * 0.9) $GCR[$ia] $GCG[$ia] $GCB[$ia] 0.85

  for ($i = 0; $i -lt $N; $i++) {
    $breath = 0.90 + 0.10 * [Math]::Sin(2 * [Math]::PI * $breathCyc[$i] * $u + [Math]::PI / 2)
    $my = $ringPos[$i] / [double]$N
    $dd = [Math]::Abs($u - $my); if ($dd -gt (1 - $dd)) { $dd = 1 - $dd }
    $lb = [Math]::Exp(-[Math]::Pow($dd * $N, 2) / 1.1)
    DrawDot $g $i 1.0 $breath 0.0 $lb
  }
  $g.Dispose()
  $bmp.Save((Join-Path $part1 ('frame{0:0000}.png' -f $f)), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

[IO.File]::WriteAllText((Join-Path $work 'desc.txt'), "$W $H $FPS`np 1 0 part0`np 0 0 part1`n")

$zipPath = Join-Path $OutDir 'bootanimation.zip'
if (Test-Path $zipPath) { [IO.File]::Delete($zipPath) }
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
function Add-Stored($zip, $file, $name) {
  $e = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::NoCompression)
  $s = $e.Open(); $bytes = [IO.File]::ReadAllBytes($file); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
}
Add-Stored $zip (Join-Path $work 'desc.txt') 'desc.txt'
[IO.Directory]::GetFiles($part0, '*.png') | Sort-Object | ForEach-Object { Add-Stored $zip $_ ('part0/' + [IO.Path]::GetFileName($_)) }
[IO.Directory]::GetFiles($part1, '*.png') | Sort-Object | ForEach-Object { Add-Stored $zip $_ ('part1/' + [IO.Path]::GetFileName($_)) }
$zip.Dispose()
[IO.Directory]::Delete($work, $true)
Write-Output ("bootanimation.zip: " + (Get-Item $zipPath).Length + " bytes; $P0+$P1 frames @ ${FPS}fps; ${W}x${H}")
