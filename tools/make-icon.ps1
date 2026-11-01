# Draws the Material "search" glyph at each size Windows asks for and packs
# them into one .ico. Run once; the result is committed.
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$pngs = @()

foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  # Everything below is in the 24x24 grid the Material icon is drawn on.
  $k = $s / 24.0

  # Rounded square behind the glyph, so the icon reads on a light taskbar and
  # on a dark one without being a silhouette on either.
  $inset = 0.5 * $k
  $r = [Math]::Max(4.5 * $k, 2.0)
  $box = New-Object System.Drawing.RectangleF $inset, $inset, ($s - 2*$inset), ($s - 2*$inset)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = 2 * $r
  $path.AddArc($box.Left, $box.Top, $d, $d, 180, 90)
  $path.AddArc($box.Right - $d, $box.Top, $d, $d, 270, 90)
  $path.AddArc($box.Right - $d, $box.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($box.Left, $box.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $back = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 47, 111, 235))
  $g.FillPath($back, $path)

  # The glyph: a ring at (9.5, 9.5) with radius 5.5 and a handle out to (20,20),
  # both two units thick, which is the Material search icon's own geometry.
  # Shifted half a unit up and left so it sits centred in the square.
  $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
  $wpen = New-Object System.Drawing.Pen $white, (2.0 * $k)
  $wpen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $wpen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

  $cx = 10.0 * $k; $cy = 10.0 * $k; $rad = 5.0 * $k
  $g.DrawEllipse($wpen, ($cx - $rad), ($cy - $rad), (2*$rad), (2*$rad))
  $g.DrawLine($wpen, (14.2 * $k), (14.2 * $k), (19.0 * $k), (19.0 * $k))

  $wpen.Dispose(); $back.Dispose(); $path.Dispose(); $g.Dispose()

  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += ,($ms.ToArray())
  $ms.Dispose(); $bmp.Dispose()
}

# ICO container: a 6 byte header, one 16 byte entry per image, then the images.
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([UInt16]0)              # reserved
$bw.Write([UInt16]1)              # 1 means icon rather than cursor
$bw.Write([UInt16]$sizes.Count)

$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  # 256 does not fit in a byte and is written as 0, which the modulo gives.
  $bw.Write([Byte]($s % 256))
  $bw.Write([Byte]($s % 256))
  $bw.Write([Byte]0)              # palette size, 0 for truecolour
  $bw.Write([Byte]0)              # reserved
  $bw.Write([UInt16]1)            # colour planes
  $bw.Write([UInt16]32)           # bits per pixel
  $bw.Write([UInt32]$pngs[$i].Length)
  $bw.Write([UInt32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $bw.Write($png) }
$bw.Flush()

$dest = Join-Path $PSScriptRoot "..\src\elephant.ico"
[System.IO.File]::WriteAllBytes($dest, $out.ToArray())
$bw.Dispose(); $out.Dispose()
"wrote {0} ({1:N0} bytes, {2} sizes)" -f $dest, (Get-Item $dest).Length, $sizes.Count
