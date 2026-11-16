<#
.SYNOPSIS
    __APP__ __VERSION__ - Splunk app source as a single readable PowerShell script.

.DESCRIPTION
    Everything below the "SOURCE FILES" line is the app's source code, one file
    at a time, each line prefixed with "#|". Those lines are plain comments:
    PowerShell never executes them, and you can read them like any text file.

    Running this script recreates the app folder and the installable package:
        <OutDir>\__APP__\                 (the app folder)
        <OutDir>\__APP__-__VERSION__.spl  (upload this to Splunk)

    Needs only Windows PowerShell 5.1 or PowerShell 7. No Python, no tar.exe.
    The app icons are the only binary files, so they are drawn by code.

.PARAMETER OutDir
    Folder to write into. Defaults to the current folder. Created if missing.
    An existing __APP__ folder there is never overwritten.

.EXAMPLE
    .\__APP__-__VERSION__.ps1 -OutDir C:\temp\splunk
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$App = '__APP__'
$Version = '__VERSION__'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Mask32 = 4294967295   # 0xFFFFFFFF as Int64 (a hex literal would be Int32 -1)

# ---------------------------------------------------------------- source files

function Read-Bundle([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $text = $text.Replace("`r`n", "`n")
    $marker = "`n#@@ SOURCE FILES @@`n"
    $start = $text.IndexOf($marker)
    if ($start -lt 0) { throw 'The SOURCE FILES section is missing from this script.' }

    $files = New-Object 'System.Collections.Generic.SortedDictionary[string,byte[]]' ([System.StringComparer]::Ordinal)
    $current = $null
    $lines = $null
    foreach ($line in $text.Substring($start + $marker.Length).Split([char]10)) {
        if ($line.StartsWith('#=== FILE ')) {
            $current = $line.Substring(10)
            $lines = New-Object 'System.Collections.Generic.List[string]'
        }
        elseif ($line.StartsWith('#=== END ') -and $null -ne $current) {
            $content = [string]::Join("`n", $lines.ToArray())
            if ($line.EndsWith('newline=1')) { $content += "`n" }
            $files[$current] = $Utf8NoBom.GetBytes($content)
            $current = $null
        }
        elseif ($null -ne $current) {
            if (-not $line.StartsWith('#|')) { throw "Corrupt source section near file $current" }
            $lines.Add($line.Substring(2))
        }
    }
    if ($null -ne $current) { throw "Source section ends inside file $current" }
    return ,$files
}

# ---------------------------------------------------------------- icons (PNG)

$CrcTable = New-Object 'System.UInt32[]' 256
for ($n = 0; $n -lt 256; $n++) {
    [int64]$c = $n
    for ($k = 0; $k -lt 8; $k++) {
        if (($c -band 1) -ne 0) { $c = 3988292384 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
    }
    $CrcTable[$n] = [uint32]$c
}

function Get-Crc32([byte[]]$Bytes) {
    [int64]$c = $Mask32
    foreach ($b in $Bytes) {
        $c = [int64]$CrcTable[[int](($c -bxor $b) -band 255)] -bxor ($c -shr 8)
    }
    return [uint32]($c -bxor $Mask32)
}

function Get-BigEndian([uint32]$Value) {
    $b = [System.BitConverter]::GetBytes($Value)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
    return ,$b
}

function Add-PngChunk([System.IO.MemoryStream]$Stream, [string]$Type, [byte[]]$Data) {
    if ($null -eq $Data) { $Data = [byte[]]@() }
    $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
    $len = Get-BigEndian ([uint32]$Data.Length)
    $Stream.Write($len, 0, 4)
    $Stream.Write($typeBytes, 0, 4)
    $Stream.Write($Data, 0, $Data.Length)
    $crc = Get-BigEndian (Get-Crc32 ([byte[]]($typeBytes + $Data)))
    $Stream.Write($crc, 0, 4)
}

# zlib stream with one uncompressed ("stored") deflate block: simple and exact.
function Get-ZlibStored([byte[]]$Data) {
    if ($Data.Length -gt 65535) { throw 'Icon too large for a single stored block.' }
    [int64]$a = 1; [int64]$b = 0
    foreach ($x in $Data) { $a = ($a + $x) % 65521; $b = ($b + $a) % 65521 }
    $ms = New-Object System.IO.MemoryStream
    $len = $Data.Length
    $nlen = (-bnot $len) -band 65535
    $head = [byte[]](0x78, 0x01, 0x01, ($len -band 255), ($len -shr 8), ($nlen -band 255), ($nlen -shr 8))
    $ms.Write($head, 0, $head.Length)
    $ms.Write($Data, 0, $Data.Length)
    $adler = Get-BigEndian ([uint32](($b * 65536) + $a))
    $ms.Write($adler, 0, 4)
    return ,$ms.ToArray()
}

# Orange square with a dark border, n x n pixels, RGBA.
function New-Icon([int]$Size) {
    $edge = [Math]::Floor($Size / 8)
    $raw = New-Object byte[] ($Size * (1 + 4 * $Size))
    $i = 0
    for ($y = 0; $y -lt $Size; $y++) {
        $raw[$i] = 0; $i++                          # filter type: none
        for ($x = 0; $x -lt $Size; $x++) {
            $border = ($x -lt $edge) -or ($y -lt $edge) -or ($x -ge $Size - $edge) -or ($y -ge $Size - $edge)
            if ($border) { $px = 0x3C, 0x44, 0x4D, 255 } else { $px = 0xF5, 0x8F, 0x1F, 255 }
            foreach ($v in $px) { $raw[$i] = $v; $i++ }
        }
    }
    $ms = New-Object System.IO.MemoryStream
    $sig = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    $ms.Write($sig, 0, 8)
    $ihdr = [byte[]]((Get-BigEndian ([uint32]$Size)) + (Get-BigEndian ([uint32]$Size)) + [byte[]](8, 6, 0, 0, 0))
    Add-PngChunk $ms 'IHDR' $ihdr
    Add-PngChunk $ms 'IDAT' (Get-ZlibStored $raw)
    $empty = [byte[]]@()
    Add-PngChunk $ms 'IEND' $empty
    return ,$ms.ToArray()
}

$Icons = @{
    'static/appIcon.png'       = 36
    'static/appIcon_2x.png'    = 72
    'static/appIconAlt.png'    = 36
    'static/appIconAlt_2x.png' = 72
}

# ---------------------------------------------------------------- tar + gzip

function Set-Field([byte[]]$Header, [int]$Offset, [int]$Length, [string]$Value) {
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Value)
    if ($bytes.Length -gt $Length) { throw "Tar field too long: $Value" }
    [Array]::Copy($bytes, 0, $Header, $Offset, $bytes.Length)
}

function ConvertTo-Octal([int64]$Value, [int]$Digits) {
    return [Convert]::ToString($Value, 8).PadLeft($Digits, '0')
}

# One ustar header block. Owner root (0/0), dirs 755, files 644.
function New-TarHeader([string]$Name, [int64]$Size, [bool]$IsDir, [int64]$MTime) {
    if ($Name -match '[^\x20-\x7E]') { throw "Non-ASCII path not supported: $Name" }
    if ($Name.Length -gt 100) { throw "Path longer than 100 characters: $Name" }
    $h = New-Object byte[] 512
    Set-Field $h 0 100 $Name
    if ($IsDir) { $mode = '0000755' } else { $mode = '0000644' }
    Set-Field $h 100 8 $mode
    Set-Field $h 108 8 '0000000'
    Set-Field $h 116 8 '0000000'
    Set-Field $h 124 12 (ConvertTo-Octal $Size 11)
    Set-Field $h 136 12 (ConvertTo-Octal $MTime 11)
    Set-Field $h 148 8 '        '
    if ($IsDir) { $type = '5' } else { $type = '0' }
    Set-Field $h 156 1 $type
    Set-Field $h 257 6 'ustar'
    Set-Field $h 263 2 '00'
    Set-Field $h 265 32 'root'
    Set-Field $h 297 32 'root'
    [int64]$sum = 0
    foreach ($x in $h) { $sum += $x }
    Set-Field $h 148 8 ((ConvertTo-Octal $sum 6) + [char]0 + ' ')
    return ,$h
}

function Write-Spl([string]$Path, $Files) {
    $mtime = [int64](([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds)
    $dirs = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($rel in $Files.Keys) {
        $parts = $rel.Split('/')
        for ($i = 1; $i -lt $parts.Length; $i++) { [void]$dirs.Add([string]::Join('/', $parts[0..($i - 1)])) }
    }
    $tar = New-Object System.IO.MemoryStream
    $root = New-TarHeader "$App/" 0 $true $mtime
    $tar.Write($root, 0, 512)
    foreach ($d in $dirs) {
        $hdr = New-TarHeader "$App/$d/" 0 $true $mtime
        $tar.Write($hdr, 0, 512)
    }
    foreach ($rel in $Files.Keys) {
        $data = [byte[]]$Files[$rel]
        $hdr = New-TarHeader "$App/$rel" $data.Length $false $mtime
        $tar.Write($hdr, 0, 512)
        $tar.Write($data, 0, $data.Length)
        $pad = (512 - ($data.Length % 512)) % 512
        if ($pad -gt 0) { $zeros = New-Object byte[] $pad; $tar.Write($zeros, 0, $pad) }
    }
    $eoa = New-Object byte[] 1024                    # end-of-archive marker
    $tar.Write($eoa, 0, 1024)
    $tarBytes = $tar.ToArray()

    $out = [System.IO.File]::Create($Path)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
        try { $gz.Write($tarBytes, 0, $tarBytes.Length) } finally { $gz.Dispose() }
    }
    finally { $out.Dispose() }
}

# ---------------------------------------------------------------- main

if (-not $PSCommandPath) { throw 'Run this as a script file (.\script.ps1), not by pasting it.' }
$files = Read-Bundle $PSCommandPath
foreach ($name in $Icons.Keys) { $files[$name] = New-Icon $Icons[$name] }

$outFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
[void][System.IO.Directory]::CreateDirectory($outFull)
$appDir = Join-Path $outFull $App
if (Test-Path -LiteralPath $appDir) { throw "Refusing to overwrite existing folder: $appDir" }

foreach ($rel in $files.Keys) {
    $target = Join-Path $appDir ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
    [System.IO.File]::WriteAllBytes($target, [byte[]]$files[$rel])
}

$spl = Join-Path $outFull "$App-$Version.spl"
Write-Spl $spl $files
Write-Output "App folder: $appDir"
Write-Output "Package:    $spl"
