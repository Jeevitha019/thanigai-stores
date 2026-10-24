$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$logoPath = Join-Path $projectRoot 'malligai_kadai\assets\thanigai_stores_logo.png'
$iconPath = Join-Path $projectRoot 'malligai_kadai\windows\runner\resources\app_icon.ico'

if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) {
  throw "The Thanigai Stores logo was not found at '$logoPath'."
}

Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile($logoPath)
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = [System.Collections.Generic.List[byte[]]]::new()

try {
  foreach ($size in $sizes) {
    $bitmap = [System.Drawing.Bitmap]::new(
      $size,
      $size,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $scale = [Math]::Min($size / $source.Width, $size / $source.Height)
        $width = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
        $left = [int](($size - $width) / 2)
        $top = [int](($size - $height) / 2)
        $graphics.DrawImage($source, $left, $top, $width, $height)
      } finally {
        $graphics.Dispose()
      }

      $png = [System.IO.MemoryStream]::new()
      try {
        $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $images.Add($png.ToArray())
      } finally {
        $png.Dispose()
      }
    } finally {
      $bitmap.Dispose()
    }
  }
} finally {
  $source.Dispose()
}

$directorySize = 6 + (16 * $sizes.Count)
$offset = $directorySize
$stream = [System.IO.File]::Create($iconPath)
$writer = [System.IO.BinaryWriter]::new($stream)
try {
  $writer.Write([UInt16]0)
  $writer.Write([UInt16]1)
  $writer.Write([UInt16]$sizes.Count)
  for ($index = 0; $index -lt $sizes.Count; $index++) {
    $size = $sizes[$index]
    $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
    $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$images[$index].Length)
    $writer.Write([UInt32]$offset)
    $offset += $images[$index].Length
  }
  foreach ($image in $images) {
    $writer.Write($image)
  }
} finally {
  $writer.Dispose()
  $stream.Dispose()
}

Write-Host "Created multi-resolution Windows icon: $iconPath"
