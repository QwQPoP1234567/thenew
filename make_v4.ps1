$ErrorActionPreference = 'Stop'
$src = (Get-ChildItem 'C:\Users\Administrator\Downloads\video' -Filter '*.vep' | Where-Object Length -EQ 36334863 | Select-Object -First 1).FullName
$b = [System.IO.File]::ReadAllBytes($src)
$auth = [System.IO.File]::ReadAllBytes('E:\huangfeng\workspace-trailer\auth.bin')
"auth.bin: $($auth.Length) bytes"
$vals = New-Object System.Collections.Generic.List[uint32]
for ($i = 0; $i -lt 200; $i += 4) {
    $v = ([uint32]$auth[$i] -bor ([uint32]$auth[$i+1] -shl 8) -bor ([uint32]$auth[$i+2] -shl 16) -bor ([uint32]$auth[$i+3] -shl 24))
    $vals.Add($v)
}
"u32 count: $($vals.Count); first 8: $($vals[0..6] -join ','); last 3: $($vals[($vals.Count-3)..($vals.Count-1)] -join ',')"

# Intelligent display: the first value 0 is the header, the last value 0x67F255D3 is the tail seal, the middle 48 covering the keyframes?
# Is 200 bytes seen? auth=200B=50 u32 the last one is the seal
# Check the value distribution
$validSamples = New-Object System.Collections.Generic.List[uint32]
foreach ($v in $vals) {
    if ($v -eq 0) { $validSamples.Add(1); continue }          # sample 0 (0-based) = sample 1 (1-based), first keyframe (IDR in sample 0)
    if ($v -lt 11687) { $validSamples.Add($v + 1) }          # 0-based -> 1-based
}
"candidate keyframe sample numbers (1-based): $($validSamples.Count)"
"first 10: $($validSamples[0..([Math]::Min(9,$validSamples.Count-1))] -join ',')"
"last 5: $($validSamples[($validSamples.Count-5)..($validSamples.Count-1)] -join ',')"

function BE32([int]$o) { return ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor [uint32]$b[$o+3] }
function FourCC([int]$o) { -join (0..3 | ForEach-Object { [char]$b[$o+$_] }) }
function ScanBoxes([int]$start, [int]$end) {
    $list = New-Object System.Collections.Generic.List[object]
    $p = $start
    while ($p -lt ($end - 8)) {
        $sz = BE32 $p; $cc = FourCC ($p + 4)
        if ($sz -lt 8 -or ($p + $sz) -gt $end -or $cc -match '[^a-zA-Z0-9]') { break }
        $list.Add(@{ off = $p; size = $sz; cc = $cc })
        if ($cc -eq 'udta') { break }
        $p += $sz
    }
    return $list
}
$top = ScanBoxes 24 36334062
$moov = $null; foreach ($bx in $top) { if ($bx.cc -eq 'moov') { $moov = $bx; break } }
$moovCh = ScanBoxes ($moov.off + 8) ($moov.off + $moov.size)
$tracks = New-Object System.Collections.Generic.List[object]
foreach ($t in $moovCh) {
    if ($t.cc -ne 'trak') { continue }
    $trk = ScanBoxes ($t.off + 8) ($t.off + $t.size)
    $md = $null; foreach ($x in $trk) { if ($x.cc -eq 'mdia') { $md = $x; break } }
    if (-not $md) { continue }
    $mdc = ScanBoxes ($md.off + 8) ($md.off + $md.size)
    $h = ''; $minfBox = $null
    foreach ($m in $mdc) { if ($m.cc -eq 'hdlr') { $h = FourCC ($m.off + 16) }; if ($m.cc -eq 'minf') { $minfBox = $m } }
    if ($minfBox) {
        $mic = ScanBoxes ($minfBox.off + 8) ($minfBox.off + $minfBox.size)
        foreach ($mi in $mic) {
            if ($mi.cc -eq 'stbl') {
                $stbl = ScanBoxes ($mi.off + 8) ($mi.off + $mi.size)
                $tables = @{}
                foreach ($t2 in $stbl) { if ($t2.cc -in @('stco','stsz','stsc','stss','stsd')) { $tables[$t2.cc] = $t2 } }
                $tracks.Add(@{ hdlr = $h; tables = $tables })
            }
        }
    }
}
foreach ($tr in $tracks) { "track hdlr=$($tr.hdlr): $($tr.tables.Keys -join ',')" }

# ---- stss rebuild using auth values ----
$video = $null; foreach ($tr in $tracks) { if ($tr.hdlr -eq 'vide') { $video = $tr; break } }
if (-not $video -or -not $video.tables['stss']) { throw 'no video stss' }
$stss = $video.tables['stss']
$cnt = BE32 ($stss.off + 12)
"stss entry_count in file = $cnt"
$entriesPos = $stss.off + 16
for ($k = 0; $k -lt $cnt; $k++) {
    $p = $entriesPos + 4*$k
    $v = [uint32]$validSamples[$k]
    $b[$p] =   [byte](($v -shr 24) -band 0xFF)
    $b[$p+1] = [byte](($v -shr 16) -band 0xFF)
    $b[$p+2] = [byte](($v -shr 8) -band 0xFF)
    $b[$p+3] = [byte]($v -band 0xFF)
}
"stss rebuilt: wrote $($validSamples.Count) entries (of $cnt slots)"

# ---- sample0 SEI repair (video chunk 0) ----
$stco = $video.tables['stco']
$chunk0Off = BE32 ($stco.off + 16)
$b[$chunk0Off+0]=0x00; $b[$chunk0Off+1]=0x00; $b[$chunk0Off+2]=0x02; $b[$chunk0Off+3]=0xAF
$b[$chunk0Off+4]=0x06; $b[$chunk0Off+5]=0x05; $b[$chunk0Off+6]=0xFF; $b[$chunk0Off+7]=0xFF
"sample0 SEI repaired @ $chunk0Off"

# ---- neutralize text + audio tracks ----
foreach ($tr in $tracks) {
    if ($tr.hdlr -eq 'soun') {
        # stsd: [hdr8][vf4][count4][entry: size4+fourcc4]
        $pw = $tr.tables['stsd'].off + 20
        $cc = FourCC $pw
        if ($cc -eq 'mp4a') { $b[$pw]=0x64; $b[$pw+1]=0x75; $b[$pw+2]=0x6D; $b[$pw+3]=0x6D; "audio stsd -> dumm" }
        else { "audio stsd unexpected cc=$cc @ $pw - leave" }
    }
    if ($tr.hdlr -in @('sbtl','text','subt','')) {
        $pw = $tr.tables['stsd'].off + 20
        $cc = FourCC $pw
        if ($cc -in @('text','tx3g')) { $b[$pw]=0x7A; $b[$pw+1]=0x7A; $b[$pw+2]=0x7A; $b[$pw+3]=0x7A; "text stsd[$cc] -> zzzz" }
        else { "text stsd cc=$cc - other format left intact" }
    }
}

# ---- truncate trailer + write ----
$mdatEnd = BE32 ($src.Length - 801 - 100) # quickly reuse: known 36334062
$mdatEnd = 36334062
$out = New-Object byte[] $mdatEnd
[Array]::Copy($b, 0, $out, 0, $mdatEnd)
$outPath = 'E:\huangfeng\1-工程统筹-标准可播-FINAL.mp4'
[System.IO.File]::WriteAllBytes($outPath, $out)
"=== FINAL saved: $outPath ($([math]::Round($out.Length/1MB,1)) MB) ==="
$sh = New-Object -ComObject Shell.Application; $dir = $sh.NameSpace((Split-Path $outPath)); $file = $dir.ParseName((Split-Path $outPath -Leaf))
foreach ($ix in 27,31,32) { $n = $dir.GetDetailsOf($null, $ix); $v = $dir.GetDetailsOf($file, $ix); "   $n = $v" }
