$ErrorActionPreference = 'Stop'
$src = (Get-ChildItem 'C:\Users\Administrator\Downloads\video' -Filter '*.vep' | Where-Object Length -EQ 36334863 | Select-Object -First 1).FullName
$b = [System.IO.File]::ReadAllBytes($src)
function BE32([int]$o) { return ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor [uint32]$b[$o+3] }
function FourCC([int]$o) { -join (0..3 | ForEach-Object { [char]$b[$o+$_] }) }
function FindBoxesAt([int[]]$positions) { }

# flat-scan: collect every top-level box offset+size+cc in moov range, then descend once for trak/mdia/minf/stbl
$moovStart = 24
$boxes = New-Object System.Collections.Generic.List[object]
$o = $moovStart
$moovSize = BE32 ($o)  # moov itself at offset 4.. wait offset 24 has size? Previously parsed: moov starts at 24 (offset 24 contains size 4b + 'moov')
$entries = New-Object System.Collections.Generic.List[object]
function ScanBoxes([int]$start, [int]$end) {
    $list = New-Object System.Collections.Generic.List[object]
    $p = $start
    while ($p -lt ($end - 8)) {
        $sz = BE32 $p; $cc = FourCC ($p + 4)
        if ($sz -lt 8 -or ($p + $sz) -gt $end -or $cc -match '[^a-zA-Z0-9]') { break }
        $list.Add(@{ off = $p; size = $sz; cc = $cc })
        if ($cc -eq 'mdat') { break }
        $p += $sz
    }
    return $list
}
$topBoxes = ScanBoxes 24 36334062
$moovEntry = $null
foreach ($bx in $topBoxes) { if ($bx.cc -eq 'moov') { $moovEntry = $bx; break } }
if (-not $moovEntry) { throw "moov not found at top level: $($topBoxes.cc -join ',')" }
"moov: off=$($moovEntry.off) size=$($moovEntry.size)"
$moovChildren = ScanBoxes ($moovEntry.off + 8) ($moovEntry.off + $moovEntry.size)
"moov children: $($moovChildren.cc -join ',')"
$tracks = New-Object System.Collections.Generic.List[object]
foreach ($t in $moovChildren) {
    if ($t.cc -ne 'trak') { continue }
    $trakChildren = ScanBoxes ($t.off + 8) ($t.off + $t.size)
    $mdiaBox = $null
    foreach ($tc in $trakChildren) { if ($tc.cc -eq 'mdia') { $mdiaBox = $tc; break } }
    if (-not $mdiaBox) { continue }
    $mdiaChildren = ScanBoxes ($mdiaBox.off + 8) ($mdiaBox.off + $mdiaBox.size)
    $h = ''
    $minfBox = $null
    foreach ($m in $mdiaChildren) {
        if ($m.cc -eq 'hdlr') { $h = FourCC ($m.off + 16) }
        if ($m.cc -eq 'minf') { $minfBox = $m }
    }
    "DEBUG trak hdlr=[$h] minf=$(if($minfBox){'yes'}else{'no'})"
    if ($minfBox) {
        $minfChildren = ScanBoxes ($minfBox.off + 8) ($minfBox.off + $minfBox.size)
        foreach ($mi in $minfChildren) {
            if ($mi.cc -eq 'stbl') {
                $stbl = ScanBoxes ($mi.off + 8) ($mi.off + $mi.size)
                $tables = @{}
                foreach ($tbx in $stbl) { if ($tbx.cc -in @('stco','stsz','stsc','stss','stsd')) { $tables[$tbx.cc] = $tbx } }
                $tracks.Add(@{ hdlr = $h; tables = $tables })
                "DEBUG   ★ track hdlr=$h tables=$($tables.Keys -join ',')"
            }
        }
    }
}
"found $($tracks.Count) tracks"
foreach ($tr in $tracks) { "  hdlr=$($tr.hdlr) tables=$($tr.tables.Keys -join ',')" }
$video = $null; $audio = $null
foreach ($tr in $tracks) {
    if ($tr.hdlr -eq 'vide' -and -not $video) { $video = $tr }
    if ($tr.hdlr -eq 'soun' -and -not $audio) { $audio = $tr }
}
if (-not $video) { throw 'no video track found' }

# parse video stco/stsz/stsc
$stco = $video.tables['stco']; $stsz = $video.tables['stsz']; $stsc = $video.tables['stsc']
$chunkCount = BE32 ($stco.off + 12)
$chas = New-Object 'System.Collections.Generic.List[uint32]'
for ($k = 0; $k -lt $chunkCount; $k++) { $chas.Add((BE32 ($stco.off + 16 + 4*$k))) }
$sampleSizeConst = BE32 ($stsz.off + 12)
$sampleCount = BE32 ($stsz.off + 16)
$stscCount = BE32 ($stsc.off + 12)
$scMap = @{}
for ($k = 0; $k -lt $stscCount; $k++) {
    $fc = BE32 ($stsc.off + 16 + 12*$k)
    $spc = BE32 ($stsc.off + 16 + 12*$k + 4)
    if ($fc -gt 2147483647) { $fc = $fc - 4294967296 }
    if ($fc -ge 0) { $scMap["c$fc"] = $spc }
}
"video: chunks=$chunkCount samples=$sampleCount stsc=$stscCount sizeMode=$(if ($sampleSizeConst) {'fixed'} else {'per-sample'})"

$sizes = New-Object 'System.Collections.Generic.List[uint32]'
if ($sampleSizeConst -ne 0) { for ($k = 0; $k -lt $sampleCount; $k++) { $sizes.Add($sampleSizeConst) } }
else { for ($k = 0; $k -lt $sampleCount; $k++) { $sizes.Add((BE32 ($stsz.off + 20 + 4*$k))) } }

$mapKeys = @($scMap.Keys | ForEach-Object { [int]($_.Substring(1)) } | Sort-Object)
$perChunk = New-Object 'System.Collections.Generic.List[int]'
$mi = 0
for ($c = 1; $c -le $chunkCount; $c++) {
    while (($mi + 1) -lt $mapKeys.Count -and $c -ge $mapKeys[$mi+1]) { $mi++ }
    if ($mi -lt $mapKeys.Count) { $perChunk.Add([int]$scMap["c$($mapKeys[$mi])"]) } else { $perChunk.Add(1) }
}

# scan samples for IDR NAL type
$idr = New-Object 'System.Collections.Generic.List[int]'
$types = @{}
$sampleNum = 0
$done = $false
for ($c = 0; $c -lt $chunkCount -and -not $done; $c++) {
    $off = [uint32]$chas[$c]
    for ($s = 0; $s -lt $perChunk[$c]; $s++) {
        $sampleNum++
        if ($sampleNum -gt $sampleCount) { $done = $true; break }
        $sz = $sizes[$sampleNum-1]
        if ($sz -ge 8) {
            $nt = $b[$off+4] -band 0x1F
            $types[$nt] = $types[$nt] + 1
            if ($nt -eq 5) { $idr.Add($sampleNum) }
        }
        $off += $sz
    }
}
"scanned $sampleNum samples; NAL type histogram:"
foreach ($kv in $types.GetEnumerator() | Sort-Object Value -Descending) { "   type$($kv.Key): $($kv.Value)" }
"IDR frames found: $($idr.Count) -> $($idr[0..([Math]::Min($idr.Count-1,9))] -join ',')..."
# locate where weird type positions are
$weird = New-Object System.Collections.Generic.List[string]
$sampleNum2 = 0
$done2 = $false
for ($c = 0; $c -lt $chunkCount -and -not $done2; $c++) {
    $off = [uint32]$chas[$c]
    for ($s = 0; $s -lt $perChunk[$c]; $s++) {
        $sampleNum2++
        if ($sampleNum2 -gt $sampleCount) { $done2 = $true; break }
        $sz = $sizes[$sampleNum2-1]
        if ($sz -ge 8) {
            $nt = $b[$off+4] -band 0x1F
            if ($nt -notin @(1,5,6,7,8,9)) { $weird.Add("s$sampleNum2(t$nt,sz$sz,c$c)") }
        }
        $off += $sz
    }
}
"weird samples: $($weird.Count) first 20 -> $($weird[0..([Math]::Min(19,$weird.Count-1))] -join ' | ')"

# rebuild stss
$stss = $video.tables['stss']
$entriesPos = $stss.off + 16
$stssEntriesPos = $stss.off + 16   # [hdr8][vf4][count4][entries]
for ($k = 0; $k -lt 49; $k++) {
    $p = $entriesPos + 4*$k
    $v = 0
    if ($k -lt $idr.Count) { $v = [uint32]$idr[$k] }
    $b[$p]= [byte](($v -shr 24) -band 0xFF); $b[$p+1]= [byte](($v -shr 16) -band 0xFF); $b[$p+2]= [byte](($v -shr 8) -band 0xFF); $b[$p+3]= [byte]($v -band 0xFF)
}
"stss rebuilt with $($idr.Count) IDR positions"

# fix sample0 SEI header
$seiPos = [uint32]$chas[0]
$b[$seiPos+0]=0x00; $b[$seiPos+1]=0x00; $b[$seiPos+2]=0x02; $b[$seiPos+3]=0xAF
$b[$seiPos+4]=0x06; $b[$seiPos+5]=0x05; $b[$seiPos+6]=0xFF; $b[$seiPos+7]=0xFF
"sample0 SEI repaired @ $seiPos"

# neutralize audio + text stsd
foreach ($tr in $tracks) {
    if ($tr.hdlr -eq 'soun') {
        $p = $tr.tables['stsd'].off + 8 + 8 + 4
        $p = $tr.tables['stsd'].off + 16
        # entry fourcc at +16 (size at +12..15, fourcc at +16..19)
        $pw = $tr.tables['stsd'].off + 16
        if ((FourCC $pw) -eq 'mp4a') { $b[$pw]=0x64; $b[$pw+1]=0x75; $b[$pw+2]=0x6D; $b[$pw+3]=0x6D; "audio stsd -> dumm" }
    }
    if ($tr.hdlr -eq 'sbtl' -or $tr.hdlr -eq 'text' -or $tr.tables['stsd'] -and $tr.hdlr -notin @('vide','soun')) {
        $pw = $tr.tables['stsd'].off + 16
        $cc = FourCC $pw
        if ($cc -in @('text','tx3g')) { $b[$pw]=0x7A; $b[$pw+1]=0x7A; $b[$pw+2]=0x7A; $b[$pw+3]=0x7A; "subtitle stsd[$cc] -> zzzz" }
    }
}

# truncate to mdat end + write
$mdatEnd = 36334062
$out = New-Object byte[] $mdatEnd
[Array]::Copy($b, 0, $out, 0, $mdatEnd)
$outPath = 'E:\huangfeng\1-工程统筹-标准可播-v3.mp4'
[System.IO.File]::WriteAllBytes($outPath, $out)
"=== V3 saved: $outPath ($([math]::Round($out.Length/1MB,1)) MB) ==="
$sh = New-Object -ComObject Shell.Application; $dir = $sh.NameSpace((Split-Path $outPath)); $file = $dir.ParseName((Split-Path $outPath -Leaf))
foreach ($ix in 27,31,32) { $n = $dir.GetDetailsOf($null, $ix); $v = $dir.GetDetailsOf($file, $ix); "   $n = $v" }
