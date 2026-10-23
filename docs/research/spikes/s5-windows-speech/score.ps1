# S5: scores every engine's transcripts against corpus.tsv and prints Markdown
# tables for the record: median latency, mixed error rate, identifier accuracy,
# and the GO check for whisper-small. Throwaway spike code (#135).
# Windows PowerShell 5.1 or PowerShell 7 (any OS).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File score.ps1 > results\score.md
#
# Tokens: every CJK ideograph is one token; every run of ASCII letters/digits is one
# token (lower-cased); punctuation and spaces are ignored. "Mixed error rate" (MER) =
# token edit distance / reference tokens, i.e. CER for Chinese and WER for English.
# Identifier accuracy: strict = the identifier appears verbatim (case-sensitive);
# loose = it appears after lower-casing and deleting everything but a-z0-9 on both
# sides (so "parse config" counts for parseConfig, "control request" for control_request).
param(
    [string]$Corpus = (Join-Path $PSScriptRoot 'corpus.tsv'),
    [string]$ResultDir = (Join-Path $PSScriptRoot 'results'),
    [string]$GoEngine = 'whisper-small',
    [int]$GoMedianMs = 2500,
    [double]$GoIdentifierLoose = 0.8
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Tokens([string]$s) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($s.ToLowerInvariant(), '\p{IsCJKUnifiedIdeographs}|[a-z0-9]+')) { $list.Add($m.Value) }
    , $list.ToArray()
}

function Distance([string[]]$a, [string[]]$b) {
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object int[] ($m + 1)
    $cur = New-Object int[] ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$m]
}

function Loose([string]$s) { ($s.ToLowerInvariant() -replace '[^a-z0-9]', '') }

function Median([double[]]$values) {
    if ($values.Count -eq 0) { return [double]::NaN }
    $sorted = $values | Sort-Object
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2
}

$corpusRows = [System.IO.File]::ReadAllLines($Corpus, $utf8) | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' } | ForEach-Object {
    $c = $_ -split "`t"
    [pscustomobject]@{ id = $c[0]; reference = $c[1]; identifiers = @($c[2] -split '\|' | Where-Object { $_ -ne '' }) }
}

$timingRows = @()
$timingsPath = Join-Path $ResultDir 'timings.csv'
if (Test-Path $timingsPath) { $timingRows = @(Import-Csv $timingsPath) }

$engines = Get-ChildItem $ResultDir -Directory | Sort-Object Name | ForEach-Object { $_.Name }
$summary = @()
$perClip = @()
foreach ($engine in $engines) {
    $errors = 0; $refTotal = 0; $idTotal = 0; $idStrict = 0; $idLoose = 0; $clipsScored = 0
    foreach ($row in $corpusRows) {
        $path = Join-Path (Join-Path $ResultDir $engine) "$($row.id).txt"
        if (-not (Test-Path $path)) { continue }
        $clipsScored++
        $hyp = ([System.IO.File]::ReadAllText($path, $utf8) -replace '\s+', ' ').Trim()
        $ref = Tokens $row.reference
        $d = Distance $ref (Tokens $hyp)
        $errors += $d; $refTotal += $ref.Length
        $strict = 0; $loose = 0
        foreach ($idf in $row.identifiers) {
            if ($hyp.Contains($idf)) { $strict++ }
            if ((Loose $hyp).Contains((Loose $idf))) { $loose++ }
        }
        $idTotal += $row.identifiers.Count; $idStrict += $strict; $idLoose += $loose
        $t = $timingRows | Where-Object { $_.engine -eq $engine -and $_.clip -eq $row.id } | Select-Object -Last 1
        $perClip += [pscustomobject]@{
            engine = $engine; clip = $row.id; wall = $(if ($t) { $t.wall_ms } else { '' })
            mer = $(if ($ref.Length) { '{0:P0}' -f ($d / $ref.Length) } else { '' })
            ids = "$strict/$loose of $($row.identifiers.Count)"; hyp = $hyp
        }
    }
    $walls = @($timingRows | Where-Object { $_.engine -eq $engine -and $_.wall_ms -ne '' } | ForEach-Object { [double]$_.wall_ms })
    $engineMs = @($timingRows | Where-Object { $_.engine -eq $engine -and $_.engine_total_ms -ne '' } | ForEach-Object { [double]$_.engine_total_ms })
    $loads = @($timingRows | Where-Object { $_.engine -eq $engine -and $_.load_ms -ne '' } | ForEach-Object { [double]$_.load_ms })
    $summary += [pscustomobject]@{
        engine = $engine; clips = $clipsScored
        medianWall = Median $walls; medianEngine = Median $engineMs; medianLoad = Median $loads
        mer = $(if ($refTotal) { $errors / $refTotal } else { [double]::NaN })
        strict = $(if ($idTotal) { $idStrict / $idTotal } else { [double]::NaN })
        loose = $(if ($idTotal) { $idLoose / $idTotal } else { [double]::NaN })
    }
}

function Fmt([double]$v, [string]$f) { if ([double]::IsNaN($v)) { 'n/a' } else { $f -f $v } }

'## Summary per engine'
''
'| Engine | Clips | Median wall (ms) | Median engine total (ms) | Median load (ms) | Mixed error rate | Identifiers strict | Identifiers loose |'
'|---|---:|---:|---:|---:|---:|---:|---:|'
foreach ($s in $summary) {
    '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $s.engine, $s.clips, (Fmt $s.medianWall '{0:N0}'), (Fmt $s.medianEngine '{0:N0}'), (Fmt $s.medianLoad '{0:N0}'), (Fmt $s.mer '{0:P1}'), (Fmt $s.strict '{0:P0}'), (Fmt $s.loose '{0:P0}')
}
''
'## Per clip'
''
'| Engine | Clip | Wall (ms) | MER | Identifiers strict/loose | Transcript |'
'|---|---|---:|---:|---|---|'
foreach ($p in $perClip) { '| {0} | {1} | {2} | {3} | {4} | {5} |' -f $p.engine, $p.clip, $p.wall, $p.mer, $p.ids, ($p.hyp -replace '\|', '\|') }
''
'## GO check'
''
$go = $summary | Where-Object { $_.engine -eq $GoEngine } | Select-Object -First 1
if ($null -eq $go) {
    "No results for $GoEngine yet."
} else {
    $latencyOk = (-not [double]::IsNaN($go.medianWall)) -and $go.medianWall -lt $GoMedianMs
    $idsOk = (-not [double]::IsNaN($go.loose)) -and $go.loose -ge $GoIdentifierLoose
    "- $GoEngine median wall latency $(Fmt $go.medianWall '{0:N0}') ms (threshold < $GoMedianMs ms): $(if ($latencyOk) { 'PASS' } else { 'FAIL' })"
    "- $GoEngine loose identifier accuracy $(Fmt $go.loose '{0:P0}') (threshold >= $('{0:P0}' -f $GoIdentifierLoose)): $(if ($idsOk) { 'PASS' } else { 'FAIL' })"
    "- Verdict: $(if ($latencyOk -and $idsOk) { 'GO' } else { 'NO-GO' })"
}
