<#
.SYNOPSIS
    licoryx_spl_owner_manager 0.1.0 - Splunk app source as a single readable PowerShell script.

.DESCRIPTION
    Everything below the "SOURCE FILES" line is the app's source code, one file
    at a time, each line prefixed with "#|". Those lines are plain comments:
    PowerShell never executes them, and you can read them like any text file.

    Running this script recreates the app folder and the installable package:
        <OutDir>\licoryx_spl_owner_manager\                 (the app folder)
        <OutDir>\licoryx_spl_owner_manager-0.1.0.spl  (upload this to Splunk)

    Needs only Windows PowerShell 5.1 or PowerShell 7. No Python, no tar.exe.
    The app icons are the only binary files, so they are drawn by code.

.PARAMETER OutDir
    Folder to write into. Defaults to the current folder. Created if missing.
    An existing licoryx_spl_owner_manager folder there is never overwritten.

.EXAMPLE
    .\licoryx_spl_owner_manager-0.1.0.ps1 -OutDir C:\temp\splunk
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$App = 'licoryx_spl_owner_manager'
$Version = '0.1.0'
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

#@@ SOURCE FILES @@
#=== FILE README.md
#|# Lookup Owner Manager (POC)
#|
#|Find CSV lookup table files and change their owner from a single page.
#|
#|## How it works
#|
#|The "Lookup Owners" page runs entirely in the browser. It calls Splunk's
#|REST API through Splunk Web using **your own session**. The app has no
#|server-side code, no stored credentials and no service account, so it can
#|never do more than your role allows.
#|
#|REST endpoints used:
#|
#|- `GET /services/authentication/current-context` (your username and capabilities)
#|- `GET /servicesNS/-/-/data/lookup-table-files` (the lookup list)
#|- `GET /services/authentication/users` (orphan detection; optional)
#|- `POST <lookup>/acl` with `owner`, the current `sharing`, and the current `perms.read` / `perms.write`
#|
#|## Permissions
#|
#|Changing another user's object normally needs the `admin_all_objects`
#|capability (`sc_admin` on Splunk Cloud, `admin` on Splunk Enterprise).
#|The "Can change owners" badge is only a hint; Splunk enforces the real check.
#|
#|A `power` user cannot change the owner even of their own lookup (tested on
#|Splunk Enterprise 10.6.1).
#|
#|Changing the owner of a private (user-shared) lookup moves the file into the
#|new owner's private space: the previous owner loses access to it.
#|
#|Private lookups that belong to a **deleted** user are not visible through the
#|REST API, so this app can't list them. To recover one, recreate the user with
#|the same name, reassign the lookup, then delete the user again.
#|
#|## Audit
#|
#|Every change is a REST call made as you, through Splunk Web. Splunk does not
#|write owner changes to `_audit`, but Splunk Web's access log records each one
#|with the acting user:
#|
#|    index=_internal sourcetype=splunkd_ui_access "POST" "/lookup-table-files/" "/acl"
#|    | rex "^\S+ - (?<acting_user>\S+) \[[^\]]+\] \"POST (?<uri>\S+)[^\"]*\" (?<status>\d+)"
#|    | table _time acting_user uri status
#|
#|Note that `_internal` has a short retention period and is not always searchable
#|by non-admins on Splunk Cloud.
#=== END README.md newline=1
#=== FILE app.manifest
#|{
#|  "schemaVersion": "2.0.0",
#|  "info": {
#|    "title": "Lookup Owner Manager",
#|    "id": {
#|      "group": null,
#|      "name": "licoryx_spl_owner_manager",
#|      "version": "0.1.0"
#|    },
#|    "author": [
#|      {
#|        "name": "Licoryx",
#|        "email": null,
#|        "company": null
#|      }
#|    ],
#|    "releaseDate": null,
#|    "description": "Find lookup table files and change their owner, using only the logged-in user's permissions.",
#|    "classification": {
#|      "intendedAudience": "Administrators",
#|      "categories": ["Utilities"],
#|      "developmentStatus": "Alpha"
#|    },
#|    "commonInformationModels": null,
#|    "license": {
#|      "name": null,
#|      "text": null,
#|      "uri": null
#|    },
#|    "privacyPolicy": {
#|      "name": null,
#|      "text": null,
#|      "uri": null
#|    },
#|    "releaseNotes": {
#|      "name": null,
#|      "text": null,
#|      "uri": null
#|    }
#|  },
#|  "dependencies": null,
#|  "tasks": null,
#|  "inputGroups": null,
#|  "incompatibleApps": null,
#|  "platformRequirements": null,
#|  "supportedDeployments": ["_standalone", "_distributed", "_search_head_clustering"],
#|  "targetWorkloads": ["_search_heads"]
#|}
#=== END app.manifest newline=1
#=== FILE appserver/static/lookup_owner_core.js
#|/*
#| * Pure logic for the Lookup Owner Manager: no DOM, no network.
#| * UMD wrapper so it loads as an AMD module in Splunk Web and as a
#| * CommonJS module in Node for unit tests.
#| */
#|(function (root, factory) {
#|    if (typeof define === 'function' && define.amd) {
#|        define([], factory);
#|    } else if (typeof module === 'object' && module.exports) {
#|        module.exports = factory();
#|    } else {
#|        root.LookupOwnerCore = factory();
#|    }
#|})(this, function () {
#|    'use strict';
#|
#|    var NOBODY = 'nobody';
#|
#|    /** Turn a lookup-table-files JSON response into flat rows. */
#|    function parseLookups(json) {
#|        var entries = (json && json.entry) || [];
#|        return entries.map(function (e) {
#|            var acl = e.acl || {};
#|            var perms = acl.perms || {};
#|            return {
#|                id: (e.links && e.links.alternate) || e.id || e.name,
#|                name: e.name,
#|                app: acl.app || '',
#|                owner: acl.owner || '',
#|                sharing: acl.sharing || '',
#|                readPerms: perms.read || [],
#|                writePerms: perms.write || [],
#|                canChangePerms: acl.can_change_perms !== false,
#|                aclPath: aclPathFor(e),
#|                path: (e.content && e.content['eai:data']) || '',
#|                updated: e.updated || ''
#|            };
#|        });
#|    }
#|
#|    /**
#|     * ACL endpoint for an entry. Splunk 10.x does not list `acl` in
#|     * entry.links for lookup-table-files, but <alternate>/acl works.
#|     */
#|    function aclPathFor(e) {
#|        var links = e.links || {};
#|        if (links.acl) return links.acl;
#|        if (links.alternate) return links.alternate.replace(/\/$/, '') + '/acl';
#|        return null;
#|    }
#|
#|    /** Names of users from an authentication/users response. */
#|    function parseUsers(json) {
#|        var entries = (json && json.entry) || [];
#|        return entries.map(function (e) { return e.name; }).sort();
#|    }
#|
#|    function isOrphan(row, userSet) {
#|        if (!userSet) return false; // unknown: user list not readable
#|        if (!row.owner || row.owner === NOBODY) return false;
#|        return !userSet.has(row.owner);
#|    }
#|
#|    /** "*" = any characters; otherwise case-insensitive substring. */
#|    function makeNameMatcher(pattern) {
#|        var p = (pattern || '').trim();
#|        if (!p) return function () { return true; };
#|        if (p.indexOf('*') === -1) {
#|            var lower = p.toLowerCase();
#|            return function (name) { return name.toLowerCase().indexOf(lower) !== -1; };
#|        }
#|        var re = new RegExp('^' + p.split('*').map(escapeRegex).join('.*') + '$', 'i');
#|        return function (name) { return re.test(name); };
#|    }
#|
#|    function escapeRegex(s) {
#|        return s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
#|    }
#|
#|    /**
#|     * filters: { name, apps: [], owners: [], sharing: [], orphanOnly }
#|     * Empty arrays mean "no filter".
#|     */
#|    function applyFilters(rows, filters, userSet) {
#|        var f = filters || {};
#|        var nameOk = makeNameMatcher(f.name);
#|        var inList = function (list, v) { return !list || list.length === 0 || list.indexOf(v) !== -1; };
#|        return rows.filter(function (r) {
#|            return nameOk(r.name) &&
#|                inList(f.apps, r.app) &&
#|                inList(f.owners, r.owner) &&
#|                inList(f.sharing, r.sharing) &&
#|                (!f.orphanOnly || isOrphan(r, userSet));
#|        });
#|    }
#|
#|    function sortRows(rows, key, dir) {
#|        var mul = dir === 'desc' ? -1 : 1;
#|        return rows.slice().sort(function (a, b) {
#|            var x = String(a[key] || '').toLowerCase();
#|            var y = String(b[key] || '').toLowerCase();
#|            return x < y ? -mul : x > y ? mul : 0;
#|        });
#|    }
#|
#|    /**
#|     * Body for POST .../acl. Splunk requires `sharing` on every ACL POST.
#|     * Current perms are re-sent so only the owner changes.
#|     */
#|    function buildAclBody(row, newOwner) {
#|        var body = { owner: newOwner, sharing: row.sharing };
#|        if (row.sharing !== 'user') {
#|            if (row.readPerms.length) body['perms.read'] = row.readPerms.join(',');
#|            if (row.writePerms.length) body['perms.write'] = row.writePerms.join(',');
#|        }
#|        return body;
#|    }
#|
#|    /**
#|     * Why a row can't be changed, or null if it can.
#|     * Private (sharing=user) lookups are allowed: on Splunk 10.6 an owner
#|     * change moves the file into the new owner's user folder.
#|     */
#|    function blockReason(row, newOwner) {
#|        if (!row.aclPath) return 'No ACL endpoint returned for this object.';
#|        if (!newOwner) return 'No new owner selected.';
#|        if (row.owner === newOwner) return 'Already owned by ' + newOwner + '.';
#|        return null;
#|    }
#|
#|    function hasCapability(caps, name) {
#|        return Array.isArray(caps) && caps.indexOf(name) !== -1;
#|    }
#|
#|    /** Pull a readable message out of a splunkd error. */
#|    function errorMessage(err) {
#|        if (!err) return 'Unknown error';
#|        var msgs = err.data && err.data.messages;
#|        if (msgs && msgs.length && msgs[0].text) return msgs[0].text;
#|        if (err.status === 403) return 'Forbidden: your role lacks permission for this object.';
#|        if (err.status) return 'HTTP ' + err.status;
#|        return String(err.message || err);
#|    }
#|
#|    function csvCell(v) {
#|        var s = Array.isArray(v) ? v.join(';') : String(v == null ? '' : v);
#|        // Neutralise spreadsheet formula injection.
#|        if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
#|        return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
#|    }
#|
#|    function toCsv(rows, userSet) {
#|        var header = ['name', 'app', 'owner', 'sharing', 'orphaned', 'perms_read', 'perms_write'];
#|        var lines = [header.join(',')];
#|        rows.forEach(function (r) {
#|            lines.push([r.name, r.app, r.owner, r.sharing, isOrphan(r, userSet),
#|                r.readPerms, r.writePerms].map(csvCell).join(','));
#|        });
#|        return lines.join('\r\n') + '\r\n';
#|    }
#|
#|    /**
#|     * Run async tasks with limited concurrency.
#|     * worker(item, done) where done(result). Calls onEach(result, index), then onAll(results).
#|     */
#|    function runLimited(items, limit, worker, onEach, onAll) {
#|        var results = new Array(items.length);
#|        var next = 0, finished = 0;
#|        if (items.length === 0) { onAll(results); return; }
#|        function launch() {
#|            if (next >= items.length) return;
#|            var i = next++;
#|            worker(items[i], function (res) {
#|                results[i] = res;
#|                if (onEach) onEach(res, i);
#|                finished++;
#|                if (finished === items.length) onAll(results);
#|                else launch();
#|            });
#|        }
#|        for (var k = 0; k < Math.min(limit, items.length); k++) launch();
#|    }
#|
#|    function escapeHtml(s) {
#|        return String(s == null ? '' : s)
#|            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
#|            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
#|    }
#|
#|    return {
#|        NOBODY: NOBODY,
#|        parseLookups: parseLookups,
#|        parseUsers: parseUsers,
#|        isOrphan: isOrphan,
#|        makeNameMatcher: makeNameMatcher,
#|        applyFilters: applyFilters,
#|        sortRows: sortRows,
#|        buildAclBody: buildAclBody,
#|        blockReason: blockReason,
#|        hasCapability: hasCapability,
#|        errorMessage: errorMessage,
#|        toCsv: toCsv,
#|        runLimited: runLimited,
#|        escapeHtml: escapeHtml
#|    };
#|});
#=== END appserver/static/lookup_owner_core.js newline=1
#=== FILE appserver/static/lookup_owners.css
#|#lom-root { font-size: 13px; }
#|#lom-root .btn { margin: 0 2px; }
#|.lom-header, .lom-actions { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
#|.lom-actions { justify-content: flex-start; }
#|.lom-actions .lom-count { margin-right: auto; }
#|.lom-title { font-size: 18px; font-weight: 600; }
#|.lom-who { color: #6b7785; }
#|.lom-badge { padding: 2px 8px; border-radius: 10px; font-size: 12px; }
#|.lom-badge-ok { background: #dff3e4; color: #1a6b33; }
#|.lom-badge-ro { background: #fdf0d5; color: #7a5200; }
#|.lom-banner { padding: 8px 12px; border-radius: 4px; margin-bottom: 10px; }
#|.lom-banner-info { background: #e8f1fb; }
#|.lom-banner-warn { background: #fdf0d5; }
#|.lom-banner-error { background: #fbe3e3; color: #8a1c1c; }
#|.lom-filters { display: flex; gap: 14px; align-items: flex-end; flex-wrap: wrap; padding: 10px; background: rgba(127,127,127,.08); border-radius: 4px; margin-bottom: 10px; }
#|.lom-filters label { display: flex; flex-direction: column; gap: 4px; margin: 0; }
#|.lom-filters select[multiple] { min-width: 180px; height: 90px; }
#|.lom-filters fieldset { border: 0; margin: 0; padding: 0; }
#|.lom-filters fieldset label, .lom-orphan-wrap { flex-direction: row !important; align-items: center; }
#|.lom-filters legend { font-size: 13px; border: 0; margin: 0 0 4px; width: auto; }
#|.lom-table th[data-key] { cursor: pointer; user-select: none; }
#|.lom-table th.lom-sorted[data-dir="asc"]::after { content: " ▲"; }
#|.lom-table th.lom-sorted[data-dir="desc"]::after { content: " ▼"; }
#|.lom-tag-orphan { background: #fbe3e3; color: #8a1c1c; border-radius: 8px; padding: 0 6px; font-size: 11px; }
#|.lom-empty { text-align: center; color: #6b7785; padding: 20px !important; }
#|.lom-pager { margin: 8px 0; }
#|.lom-results { margin-top: 16px; }
#|.lom-ok td:last-child { color: #1a6b33; }
#|.lom-fail td:last-child { color: #8a1c1c; }
#|.lom-skip { color: #6b7785; }
#|.lom-warn { background: #fdf0d5; color: #5a3d00; padding: 8px; border-radius: 4px; }
#|.lom-modal { position: fixed; inset: 0; background: rgba(0,0,0,.45); z-index: 1000; display: flex; align-items: center; justify-content: center; }
#|.lom-modal[hidden] { display: none; }
#|.lom-modal-body { background: #fff; color: #222; padding: 20px; border-radius: 6px; width: min(720px, 92vw); max-height: 85vh; overflow: auto; }
#|.lom-modal-body label { display: block; margin: 10px 0; }
#|.lom-preview { max-height: 300px; overflow: auto; margin: 10px 0; }
#|.lom-modal-actions { text-align: right; margin-top: 12px; }
#=== END appserver/static/lookup_owners.css newline=1
#=== FILE appserver/static/lookup_owners.js
#|/*
#| * Lookup Owner Manager - dashboard controller.
#| *
#| * Every REST call goes through Splunk Web with the logged-in user's
#| * session (splunkjs service adds the CSRF form key). Nothing here runs
#| * server-side or with elevated privileges: Splunk decides what is allowed.
#| */
#|require([
#|    'jquery',
#|    'splunkjs/mvc',
#|    '../app/licoryx_spl_owner_manager/lookup_owner_core',
#|    'splunkjs/mvc/simplexml/ready!'
#|], function ($, mvc, core) {
#|    'use strict';
#|
#|    var CONCURRENCY = 3;
#|    var PAGE_SIZES = [25, 50, 100];
#|    var service = mvc.createService({ owner: 'nobody' });
#|    var esc = core.escapeHtml;
#|
#|    var state = {
#|        user: null,
#|        caps: [],
#|        canChange: false,
#|        rows: [],
#|        users: null,       // array of names, or null if not readable
#|        userSet: null,
#|        filtered: [],
#|        selected: {},      // id -> row
#|        sortKey: 'name',
#|        sortDir: 'asc',
#|        page: 0,
#|        pageSize: 50,
#|        filters: { name: '', apps: [], owners: [], sharing: [], orphanOnly: false },
#|        lastResults: null
#|    };
#|
#|    // ---------- REST helpers ----------
#|
#|    function get(path, params) {
#|        var d = $.Deferred();
#|        service.get(path, $.extend({ output_mode: 'json' }, params || {}), function (err, res) {
#|            if (err) d.reject(err); else d.resolve(res.data);
#|        });
#|        return d.promise();
#|    }
#|
#|    function post(path, body, cb) {
#|        // No output_mode here: the ACL handler rejects unknown arguments.
#|        service.post(path, body, function (err) { cb(err || null); });
#|    }
#|
#|    // ---------- Layout ----------
#|
#|    var $root = $('#lom-root');
#|    $root.html([
#|        '<div class="lom-header">',
#|        '  <div><span class="lom-title">Lookup owners</span> <span class="lom-who"></span></div>',
#|        '  <div><span class="lom-badge"></span> <button class="btn lom-refresh">Refresh</button></div>',
#|        '</div>',
#|        '<div class="lom-banner" hidden></div>',
#|        '<div class="lom-filters">',
#|        '  <label>Name<input type="text" class="lom-f-name" placeholder="e.g. *_assets.csv"></label>',
#|        '  <label>App<select multiple class="lom-f-apps"></select></label>',
#|        '  <label>Owner<select multiple class="lom-f-owners"></select></label>',
#|        '  <fieldset><legend>Sharing</legend>',
#|        '    <label><input type="checkbox" class="lom-f-sharing" value="user"> Private</label>',
#|        '    <label><input type="checkbox" class="lom-f-sharing" value="app"> App</label>',
#|        '    <label><input type="checkbox" class="lom-f-sharing" value="global"> Global</label>',
#|        '  </fieldset>',
#|        '  <label class="lom-orphan-wrap"><input type="checkbox" class="lom-f-orphan"> Orphaned only</label>',
#|        '  <button class="btn lom-clear">Clear filters</button>',
#|        '</div>',
#|        '<div class="lom-actions">',
#|        '  <span class="lom-count"></span>',
#|        '  <button class="btn btn-primary lom-change" disabled>Change owner…</button>',
#|        '  <button class="btn lom-export">Export CSV</button>',
#|        '  <label>Rows <select class="lom-pagesize"></select></label>',
#|        '</div>',
#|        '<table class="table table-chrome lom-table">',
#|        '  <thead><tr>',
#|        '    <th><input type="checkbox" class="lom-select-page" title="Select page"></th>',
#|        '    <th data-key="name">Name</th><th data-key="app">App</th>',
#|        '    <th data-key="owner">Owner</th><th data-key="sharing">Sharing</th>',
#|        '    <th>Read</th><th>Write</th>',
#|        '  </tr></thead><tbody></tbody>',
#|        '</table>',
#|        '<div class="lom-pager"></div>',
#|        '<div class="lom-results" hidden></div>',
#|        '<div class="lom-modal" hidden><div class="lom-modal-body"></div></div>'
#|    ].join(''));
#|
#|    PAGE_SIZES.forEach(function (n) {
#|        $root.find('.lom-pagesize').append($('<option>').val(n).text(n).prop('selected', n === state.pageSize));
#|    });
#|
#|    function banner(msg, kind) {
#|        var $b = $root.find('.lom-banner');
#|        if (!msg) { $b.attr('hidden', true).empty(); return; }
#|        $b.removeAttr('hidden').attr('class', 'lom-banner lom-banner-' + (kind || 'info')).text(msg);
#|    }
#|
#|    // ---------- Loading ----------
#|
#|    function load() {
#|        banner('Loading…');
#|        state.selected = {};
#|        var ctx = get('/services/authentication/current-context').then(function (d) {
#|            var c = (d.entry && d.entry[0] && d.entry[0].content) || {};
#|            state.user = c.username;
#|            state.caps = c.capabilities || [];
#|        });
#|        var lookups = get('/servicesNS/-/-/data/lookup-table-files', { count: 0 }).then(function (d) {
#|            state.rows = core.parseLookups(d);
#|        });
#|        // Users are optional. Without edit_user, splunkd returns only the
#|        // caller's own account, which would make every other owner look
#|        // orphaned, so the list is ignored in that case.
#|        var users = $.Deferred();
#|        get('/services/authentication/users', { count: 0, f: 'title' }).then(
#|            function (d) { users.resolve(core.parseUsers(d)); },
#|            function () { users.resolve(null); }
#|        );
#|
#|        $.when(ctx, lookups, users).then(function (a, b, userList) {
#|            var full = userList && core.hasCapability(state.caps, 'edit_user');
#|            state.users = full ? userList : null;
#|            state.userSet = full ? new Set(userList) : null;
#|            state.canChange = core.hasCapability(state.caps, 'admin_all_objects');
#|            renderHeader();
#|            populateFilterOptions();
#|            banner(state.users ? null :
#|                'You cannot list users, so the orphan filter is off and the new owner must be typed in.', 'warn');
#|            refresh();
#|        }, function (err) {
#|            banner('Failed to load lookups: ' + core.errorMessage(err), 'error');
#|        });
#|    }
#|
#|    function renderHeader() {
#|        $root.find('.lom-who').text('as ' + (state.user || '?'));
#|        $root.find('.lom-badge')
#|            .attr('class', 'lom-badge ' + (state.canChange ? 'lom-badge-ok' : 'lom-badge-ro'))
#|            .text(state.canChange ? 'Can change owners' : 'Read-only (no admin_all_objects)')
#|            .attr('title', 'A hint only. Splunk enforces permissions on every change.');
#|        $root.find('.lom-orphan-wrap').toggle(!!state.userSet);
#|    }
#|
#|    function fillSelect($sel, values, chosen) {
#|        $sel.empty();
#|        values.forEach(function (v) {
#|            $sel.append($('<option>').val(v).text(v).prop('selected', chosen.indexOf(v) !== -1));
#|        });
#|    }
#|
#|    function uniq(list) {
#|        return Array.from(new Set(list)).sort();
#|    }
#|
#|    function populateFilterOptions() {
#|        fillSelect($root.find('.lom-f-apps'), uniq(state.rows.map(function (r) { return r.app; })), state.filters.apps);
#|        fillSelect($root.find('.lom-f-owners'), uniq(state.rows.map(function (r) { return r.owner; })), state.filters.owners);
#|    }
#|
#|    // ---------- Filtering / rendering ----------
#|
#|    function readFilters() {
#|        state.filters = {
#|            name: $root.find('.lom-f-name').val(),
#|            apps: $root.find('.lom-f-apps').val() || [],
#|            owners: $root.find('.lom-f-owners').val() || [],
#|            sharing: $root.find('.lom-f-sharing:checked').map(function () { return this.value; }).get(),
#|            orphanOnly: $root.find('.lom-f-orphan').is(':checked')
#|        };
#|    }
#|
#|    function refresh() {
#|        state.filtered = core.sortRows(core.applyFilters(state.rows, state.filters, state.userSet),
#|            state.sortKey, state.sortDir);
#|        var maxPage = Math.max(0, Math.ceil(state.filtered.length / state.pageSize) - 1);
#|        if (state.page > maxPage) state.page = maxPage;
#|        renderTable();
#|    }
#|
#|    function selectedRows() {
#|        return Object.keys(state.selected).map(function (k) { return state.selected[k]; });
#|    }
#|
#|    function renderTable() {
#|        var start = state.page * state.pageSize;
#|        var pageRows = state.filtered.slice(start, start + state.pageSize);
#|        var html = pageRows.map(function (r) {
#|            var orphan = core.isOrphan(r, state.userSet);
#|            return '<tr data-id="' + esc(r.id) + '">' +
#|                '<td><input type="checkbox" class="lom-row"' + (state.selected[r.id] ? ' checked' : '') + '></td>' +
#|                '<td>' + esc(r.name) + '</td><td>' + esc(r.app) + '</td>' +
#|                '<td>' + esc(r.owner) + (orphan ? ' <span class="lom-tag-orphan">orphaned</span>' : '') + '</td>' +
#|                '<td>' + esc(r.sharing) + '</td>' +
#|                '<td>' + esc(r.readPerms.join(', ')) + '</td><td>' + esc(r.writePerms.join(', ')) + '</td>' +
#|                '</tr>';
#|        }).join('');
#|        $root.find('.lom-table tbody').html(html || '<tr><td colspan="7" class="lom-empty">No lookups match the filters.</td></tr>');
#|
#|        $root.find('.lom-table th[data-key]').each(function () {
#|            var k = $(this).data('key');
#|            $(this).toggleClass('lom-sorted', k === state.sortKey)
#|                .attr('data-dir', k === state.sortKey ? state.sortDir : null);
#|        });
#|        $root.find('.lom-select-page').prop('checked',
#|            pageRows.length > 0 && pageRows.every(function (r) { return state.selected[r.id]; }));
#|
#|        var n = state.filtered.length;
#|        var sel = selectedRows().length;
#|        $root.find('.lom-count').text(
#|            (n ? 'Showing ' + (start + 1) + '–' + Math.min(n, start + state.pageSize) + ' of ' + n : '0 lookups') +
#|            ' (' + state.rows.length + ' total)' + (sel ? ' · ' + sel + ' selected' : ''));
#|        $root.find('.lom-change').prop('disabled', sel === 0);
#|
#|        var pages = Math.ceil(n / state.pageSize);
#|        $root.find('.lom-pager').html(pages > 1 ?
#|            '<button class="btn lom-prev"' + (state.page === 0 ? ' disabled' : '') + '>‹ Prev</button> ' +
#|            'Page ' + (state.page + 1) + ' of ' + pages +
#|            ' <button class="btn lom-next"' + (state.page >= pages - 1 ? ' disabled' : '') + '>Next ›</button>' : '');
#|    }
#|
#|    // ---------- Change owner modal ----------
#|
#|    function openModal() {
#|        var rows = selectedRows();
#|        var userOpts = (state.users || []).concat([core.NOBODY]).map(function (u) {
#|            return '<option value="' + esc(u) + '">';
#|        }).join('');
#|        var hasPrivate = rows.some(function (r) { return r.sharing === 'user'; });
#|        $root.find('.lom-modal-body').html(
#|            '<h3>Change owner of ' + rows.length + ' lookup' + (rows.length === 1 ? '' : 's') + '</h3>' +
#|            '<label>New owner <input type="text" class="lom-new-owner" list="lom-users" autocomplete="off"></label>' +
#|            '<datalist id="lom-users">' + userOpts + '</datalist>' +
#|            (hasPrivate ? '<p class="lom-warn">Some lookups are private. Splunk moves a private lookup into the new ' +
#|                'owner\'s private space: the new owner gets it and the previous owner loses access to it.</p>' : '') +
#|            '<div class="lom-preview"></div>' +
#|            (rows.length > 1 ? '<label>Type <b>' + rows.length + '</b> to confirm <input type="text" class="lom-confirm-count" size="6"></label>' : '') +
#|            '<div class="lom-modal-actions"><button class="btn lom-cancel">Cancel</button> ' +
#|            '<button class="btn btn-primary lom-confirm" disabled>Change owner</button></div>');
#|        $root.find('.lom-modal').removeAttr('hidden');
#|        updatePreview();
#|        $root.find('.lom-new-owner').trigger('focus');
#|    }
#|
#|    function modalOpts() {
#|        return { owner: $.trim($root.find('.lom-new-owner').val() || '') };
#|    }
#|
#|    function updatePreview() {
#|        var o = modalOpts();
#|        var rows = selectedRows();
#|        var ok = 0;
#|        var html = '<table class="table"><thead><tr><th>Lookup</th><th>App</th><th>Change</th></tr></thead><tbody>' +
#|            rows.map(function (r) {
#|                var why = core.blockReason(r, o.owner);
#|                if (!why) ok++;
#|                return '<tr' + (why ? ' class="lom-skip"' : '') + '><td>' + esc(r.name) + '</td><td>' + esc(r.app) + '</td><td>' +
#|                    (why ? 'Skipped: ' + esc(why) : esc(r.owner) + ' → ' + esc(o.owner)) + '</td></tr>';
#|            }).join('') + '</tbody></table>';
#|        $root.find('.lom-preview').html(html);
#|        var countOk = rows.length <= 1 || $.trim($root.find('.lom-confirm-count').val()) === String(rows.length);
#|        $root.find('.lom-confirm').prop('disabled', ok === 0 || !countOk).text('Change owner (' + ok + ')');
#|    }
#|
#|    function closeModal() {
#|        $root.find('.lom-modal').attr('hidden', true);
#|    }
#|
#|    function execute() {
#|        var o = modalOpts();
#|        var rows = selectedRows();
#|        var todo = [], results = [];
#|        rows.forEach(function (r) {
#|            var why = core.blockReason(r, o.owner);
#|            if (why) results.push({ row: r, ok: false, skipped: true, msg: why });
#|            else todo.push(r);
#|        });
#|        closeModal();
#|        showResults(results, todo.length, o.owner);
#|
#|        core.runLimited(todo, CONCURRENCY, function (r, done) {
#|            post(r.aclPath, core.buildAclBody(r, o.owner), function (err) {
#|                done({ row: r, ok: !err, msg: err ? core.errorMessage(err) : 'Owner changed to ' + o.owner });
#|            });
#|        }, function (res) {
#|            results.push(res);
#|            showResults(results, todo.length, o.owner);
#|        }, function () {
#|            state.lastResults = { results: results, owner: o.owner };
#|            showResults(results, 0, o.owner, true);
#|            load(); // re-read what Splunk actually has
#|        });
#|    }
#|
#|    function showResults(results, pending, owner, finished) {
#|        var ok = results.filter(function (r) { return r.ok; }).length;
#|        var failed = results.filter(function (r) { return !r.ok && !r.skipped; }).length;
#|        var skipped = results.filter(function (r) { return r.skipped; }).length;
#|        var $r = $root.find('.lom-results').removeAttr('hidden');
#|        $r.html('<h3>Results' + (finished ? '' : ' (running…)') + '</h3>' +
#|            '<p>' + ok + ' changed, ' + failed + ' failed, ' + skipped + ' skipped' + (finished ? '' : '') + '.' +
#|            (finished && failed ? ' <button class="btn lom-retry">Retry failed</button>' : '') +
#|            ' <button class="btn lom-dismiss">Dismiss</button></p>' +
#|            '<table class="table"><tbody>' + results.map(function (r) {
#|                return '<tr class="' + (r.ok ? 'lom-ok' : r.skipped ? 'lom-skip' : 'lom-fail') + '"><td>' +
#|                    esc(r.row.app) + ' / ' + esc(r.row.name) + '</td><td>' + esc(r.msg) + '</td></tr>';
#|            }).join('') + '</tbody></table>');
#|    }
#|
#|    function retryFailed() {
#|        var last = state.lastResults;
#|        if (!last) return;
#|        var failedKeys = {};
#|        last.results.forEach(function (r) {
#|            if (!r.ok && !r.skipped) failedKeys[r.row.app + '\u0000' + r.row.name + '\u0000' + r.row.owner] = true;
#|        });
#|        // Rows were reloaded; pick fresh copies so the ACL body uses current values.
#|        state.selected = {};
#|        state.rows.forEach(function (r) {
#|            if (failedKeys[r.app + '\u0000' + r.name + '\u0000' + r.owner]) state.selected[r.id] = r;
#|        });
#|        renderTable();
#|        openModal();
#|        $root.find('.lom-new-owner').val(last.owner);
#|        updatePreview();
#|    }
#|
#|    function exportCsv() {
#|        var blob = new Blob([core.toCsv(state.filtered, state.userSet)], { type: 'text/csv' });
#|        var a = document.createElement('a');
#|        a.href = URL.createObjectURL(blob);
#|        a.download = 'lookup_owners.csv';
#|        document.body.appendChild(a);
#|        a.click();
#|        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 0);
#|    }
#|
#|    // ---------- Events ----------
#|
#|    var nameTimer;
#|    $root.on('input', '.lom-f-name', function () {
#|        clearTimeout(nameTimer);
#|        nameTimer = setTimeout(function () { readFilters(); state.page = 0; refresh(); }, 200);
#|    });
#|    $root.on('change', '.lom-f-apps, .lom-f-owners, .lom-f-sharing, .lom-f-orphan', function () {
#|        readFilters(); state.page = 0; refresh();
#|    });
#|    $root.on('click', '.lom-clear', function () {
#|        $root.find('.lom-f-name').val('');
#|        $root.find('.lom-f-apps option, .lom-f-owners option').prop('selected', false);
#|        $root.find('.lom-f-sharing, .lom-f-orphan').prop('checked', false);
#|        readFilters(); state.page = 0; refresh();
#|    });
#|    $root.on('click', 'th[data-key]', function () {
#|        var k = $(this).data('key');
#|        if (state.sortKey === k) state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
#|        else { state.sortKey = k; state.sortDir = 'asc'; }
#|        refresh();
#|    });
#|    $root.on('change', '.lom-row', function () {
#|        var id = $(this).closest('tr').attr('data-id');
#|        var row = state.filtered.find(function (r) { return r.id === id; });
#|        if (this.checked && row) state.selected[id] = row; else delete state.selected[id];
#|        renderTable();
#|    });
#|    $root.on('change', '.lom-select-page', function () {
#|        var start = state.page * state.pageSize;
#|        var on = this.checked;
#|        state.filtered.slice(start, start + state.pageSize).forEach(function (r) {
#|            if (on) state.selected[r.id] = r; else delete state.selected[r.id];
#|        });
#|        renderTable();
#|    });
#|    $root.on('change', '.lom-pagesize', function () { state.pageSize = +this.value; state.page = 0; refresh(); });
#|    $root.on('click', '.lom-prev', function () { state.page--; renderTable(); });
#|    $root.on('click', '.lom-next', function () { state.page++; renderTable(); });
#|    $root.on('click', '.lom-refresh', load);
#|    $root.on('click', '.lom-export', exportCsv);
#|    $root.on('click', '.lom-change', openModal);
#|    $root.on('click', '.lom-cancel', closeModal);
#|    $root.on('input change', '.lom-new-owner, .lom-confirm-count', updatePreview);
#|    $root.on('click', '.lom-confirm', execute);
#|    $root.on('click', '.lom-retry', retryFailed);
#|    $root.on('click', '.lom-dismiss', function () { $root.find('.lom-results').attr('hidden', true); });
#|    $(document).on('keydown', function (e) { if (e.key === 'Escape') closeModal(); });
#|
#|    load();
#|});
#=== END appserver/static/lookup_owners.js newline=1
#=== FILE default/app.conf
#|[id]
#|name = licoryx_spl_owner_manager
#|version = 0.1.0
#|
#|[package]
#|id = licoryx_spl_owner_manager
#|check_for_updates = false
#|
#|[install]
#|is_configured = 0
#|state = enabled
#|
#|[ui]
#|is_visible = 1
#|label = Lookup Owner Manager
#|
#|[launcher]
#|author = Licoryx
#|description = Find lookup table files and change their owner, using only the logged-in user's permissions.
#|version = 0.1.0
#=== END default/app.conf newline=1
#=== FILE default/data/ui/nav/default.xml
#|<nav search_view="search" color="#3C444D">
#|  <view name="lookup_owners" default="true" />
#|</nav>
#=== END default/data/ui/nav/default.xml newline=1
#=== FILE default/data/ui/views/lookup_owners.xml
#|<dashboard version="1.1" script="lookup_owners.js" stylesheet="lookup_owners.css" hideEdit="true" hideExport="true">
#|  <label>Lookup Owners</label>
#|  <description>Find lookup table files and change their owner. Uses only your own Splunk permissions.</description>
#|  <row>
#|    <panel>
#|      <html>
#|        <div id="lom-root">Loading…</div>
#|      </html>
#|    </panel>
#|  </row>
#|</dashboard>
#=== END default/data/ui/views/lookup_owners.xml newline=1
#=== FILE metadata/default.meta
#|# Everyone can read app objects; Splunk still enforces each user's own
#|# permissions on every REST call the page makes.
#|[]
#|access = read : [ * ], write : [ admin, sc_admin ]
#|export = none
#=== END metadata/default.meta newline=1
