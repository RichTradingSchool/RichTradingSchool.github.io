# 링크 페이지 방문 통계 수집기
#
# ntfy 는 저장소가 아니라 알림 배달용이라 메시지를 12시간만 캐시한다.
# 그래서 주기적으로 긁어와 원본을 영구 보관해야 한다.
#
#   tools\events.jsonl : 원본 이벤트 영구 보관 (append-only, 진실의 원천)
#   stats.json         : 공개용 집계 — 매번 원본에서 전체 재계산해서 덮어씀
#
# 집계를 원본에서 매번 다시 만들기 때문에, 나중에 보고 싶은 지표가 생기면
# 이 스크립트만 고치면 과거 데이터까지 소급 적용된다.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$topic      = 'rich-linkbio-v-k3n8x5q2'
$repo       = Split-Path -Parent $PSScriptRoot
$eventsPath = Join-Path $PSScriptRoot 'events.jsonl'
$outPath    = Join-Path $repo 'stats.json'
$logPath    = Join-Path $PSScriptRoot 'collect.log'

# 개발 중 테스트로 발생시킨 이벤트들 — 실제 방문 통계에 섞이면 안 됨
$excludeVids = @('7unq49xcex', 'BEACONTEST', 'DEVTEST01')

function Write-Log($msg) {
    Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}

# ── 1. 이미 보관 중인 이벤트 id 파악 (중복 적재 방지) ───────────────
$seen = [System.Collections.Generic.HashSet[string]]::new()
$raw = New-Object System.Collections.Generic.List[object]
if (Test-Path $eventsPath) {
    foreach ($line in [IO.File]::ReadAllLines($eventsPath)) {
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        [void]$seen.Add([string]$o.id)
        $raw.Add($o)
    }
}

# ── 2. ntfy 폴링 → 새 이벤트만 원본 로그에 덧붙임 ──────────────────
$resp = Invoke-WebRequest "https://ntfy.sh/$topic/json?poll=1&since=all" -UseBasicParsing -TimeoutSec 60
$text = [Text.Encoding]::UTF8.GetString($resp.Content)
$lines = $text -split "`n" | Where-Object { $_.Trim() }

$fresh = New-Object System.Collections.Generic.List[string]
$new = 0
foreach ($line in $lines) {
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    if ($ev.event -ne 'message' -or -not $ev.message) { continue }
    if ($seen.Contains([string]$ev.id)) { continue }
    try { $m = $ev.message | ConvertFrom-Json } catch { continue }
    if ($excludeVids -contains [string]$m.v) { continue }

    $rec = [ordered]@{ id = $ev.id; t = [int64]$ev.time; m = $m }
    $json = ($rec | ConvertTo-Json -Depth 5 -Compress)
    $fresh.Add($json)
    $raw.Add(($json | ConvertFrom-Json))
    [void]$seen.Add([string]$ev.id)
    $new++
}
if ($fresh.Count) { Add-Content -Path $eventsPath -Value $fresh -Encoding UTF8 }

# ── 3. 원본 전체에서 집계 재계산 ───────────────────────────────────
# 날짜(KST)별로 모으고, 세션 단위 지표(체류·스크롤·재진입)는 세션별 최댓값을 취한다
$days = @{}
function New-Day {
    @{
        vids = [System.Collections.Generic.HashSet[string]]::new()
        newVids = [System.Collections.Generic.HashSet[string]]::new()
        sids = [System.Collections.Generic.HashSet[string]]::new()
        views = 0
        clicks = @{}
        src = @{}
        hours = @{}
        dwell = @{}   # sid -> 최대 체류(초)
        scroll = @{}  # sid -> 최대 스크롤(%)
        back = @{}    # sid -> 재진입 횟수
    }
}

foreach ($o in $raw) {
    $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$o.t).ToOffset([TimeSpan]::FromHours(9))
    $day = $dt.ToString('yyyy-MM-dd')
    $hour = $dt.ToString('HH')
    if (-not $days.ContainsKey($day)) { $days[$day] = New-Day }
    $b = $days[$day]
    $m = $o.m
    $sid = if ($m.sid) { [string]$m.sid } else { 'legacy-' + [string]$m.v }

    if (-not $b.hours.ContainsKey($hour)) { $b.hours[$hour] = @{ views = 0; clicks = 0 } }

    if ($m.p) {
        $b.views++
        $b.hours[$hour].views++
        if ($m.v) {
            [void]$b.vids.Add([string]$m.v)
            # n(방문 횟수)이 1이면 첫 방문, 없으면(구버전 이벤트) 판단 보류
            if ($m.n -and [int]$m.n -eq 1) { [void]$b.newVids.Add([string]$m.v) }
        }
        [void]$b.sids.Add($sid)
        if ($m.s) { $s = [string]$m.s; $b.src[$s] = [int]$b.src[$s] + 1 }
    }
    if ($m.c) {
        $c = [string]$m.c
        $b.clicks[$c] = [int]$b.clicks[$c] + 1
        $b.hours[$hour].clicks++
    }
    # 이탈 시점 이벤트 — 같은 세션이 여러 번 보내므로 최댓값만 남긴다
    if ($m.PSObject.Properties['d']) {
        $d = [int]$m.d
        if (-not $b.dwell.ContainsKey($sid) -or $d -gt $b.dwell[$sid]) { $b.dwell[$sid] = $d }
    }
    if ($m.PSObject.Properties['sc']) {
        $sc = [int]$m.sc
        if (-not $b.scroll.ContainsKey($sid) -or $sc -gt $b.scroll[$sid]) { $b.scroll[$sid] = $sc }
    }
    if ($m.PSObject.Properties['b']) {
        $bk = [int]$m.b
        if (-not $b.back.ContainsKey($sid) -or $bk -gt $b.back[$sid]) { $b.back[$sid] = $bk }
    }
}

function Get-Avg($vals) { if (-not $vals.Count) { return 0 }; [Math]::Round((($vals | Measure-Object -Sum).Sum / $vals.Count), 1) }
function Get-Median($vals) {
    if (-not $vals.Count) { return 0 }
    $s = @($vals | Sort-Object)
    if ($s.Count % 2) { return $s[[int](($s.Count - 1) / 2)] }
    return [Math]::Round((($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2), 1)
}

$pub = [ordered]@{ updated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); days = [ordered]@{} }
foreach ($k in ($days.Keys | Sort-Object -Descending)) {
    $b = $days[$k]
    $dwellVals  = @($b.dwell.Values)
    $scrollVals = @($b.scroll.Values)
    $backVals   = @($b.back.Values)
    $hours = [ordered]@{}
    foreach ($h in ($b.hours.Keys | Sort-Object)) { $hours[$h] = $b.hours[$h] }

    $pub.days[$k] = [ordered]@{
        visitors     = $b.vids.Count
        newVisitors  = $b.newVids.Count
        views        = $b.views
        sessions     = $b.sids.Count
        clicks       = $b.clicks
        src          = $b.src
        hours        = $hours
        dwellAvg     = Get-Avg $dwellVals
        dwellMedian  = Get-Median $dwellVals
        dwellSamples = $dwellVals.Count
        scrollAvg    = Get-Avg $scrollVals
        backTotal    = if ($backVals.Count) { ($backVals | Measure-Object -Sum).Sum } else { 0 }
    }
}
$pub | ConvertTo-Json -Depth 8 | Set-Content $outPath -Encoding UTF8

Write-Log "polled=$($lines.Count) new=$new stored=$($raw.Count) days=$($days.Count)"

# ── 4. 새 이벤트가 있을 때만 배포 (커밋 히스토리가 지저분해지지 않게) ──
if ($new -gt 0) {
    Push-Location $repo
    try {
        git add stats.json
        git commit -m "Update visit stats ($new new events)" | Out-Null
        git push | Out-Null
        Write-Log "pushed"
    } catch {
        Write-Log "push failed: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
}
