# 링크 페이지 방문 통계 수집기
#
# ntfy 무료 채널은 메시지를 12시간만 보관하므로, 주기적으로 폴링해서
# 일별 집계로 눌러 담아야 장기 기록이 남는다.
#   - tools\history.json : 로컬 상태 (방문자 id 집합 + 처리한 메시지 id) — 저장소에 올리지 않음
#   - stats.json         : 공개용 집계 (숫자만) — GitHub Pages 로 배포되어 통계 페이지가 읽음
#
# 실행 주기는 6시간 이하로 잡아야 한다 (12시간 보관이므로 여유를 둠).
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$topic    = 'rich-linkbio-v-k3n8x5q2'
$repo     = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $PSScriptRoot 'history.json'
$outPath   = Join-Path $repo 'stats.json'
$logPath   = Join-Path $PSScriptRoot 'collect.log'

function Write-Log($msg) {
    Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}

# ── 1. 로컬 상태 읽기 ────────────────────────────────────────────
# days: 날짜별 { vids: [방문자id], views, clicks{}, src{} }
# seen: 이미 처리한 ntfy 메시지 id → 날짜 (폴링이 겹쳐도 중복 집계 안 되게)
$days = @{}
$seen = @{}
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $state.days.PSObject.Properties) {
        $d = $p.Value
        $days[$p.Name] = @{
            vids   = [System.Collections.Generic.HashSet[string]]::new([string[]]@($d.vids))
            views  = [int]$d.views
            clicks = @{}
            src    = @{}
        }
        if ($d.clicks) { foreach ($c in $d.clicks.PSObject.Properties) { $days[$p.Name].clicks[$c.Name] = [int]$c.Value } }
        if ($d.src)    { foreach ($s in $d.src.PSObject.Properties)    { $days[$p.Name].src[$s.Name]    = [int]$s.Value } }
    }
    foreach ($p in $state.seen.PSObject.Properties) { $seen[$p.Name] = $p.Value }
}

# ── 2. ntfy 폴링 ─────────────────────────────────────────────────
$resp = Invoke-WebRequest "https://ntfy.sh/$topic/json?poll=1&since=all" -UseBasicParsing -TimeoutSec 60
$text = [Text.Encoding]::UTF8.GetString($resp.Content)
$lines = $text -split "`n" | Where-Object { $_.Trim() }

$new = 0
foreach ($line in $lines) {
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    if ($ev.event -ne 'message' -or -not $ev.message) { continue }
    if ($seen.ContainsKey($ev.id)) { continue }          # 이전 실행에서 이미 집계함

    try { $m = $ev.message | ConvertFrom-Json } catch { continue }

    # ntfy time 은 UTC 유닉스초 → KST 기준 날짜로 환산
    $day = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ev.time).ToOffset([TimeSpan]::FromHours(9)).ToString('yyyy-MM-dd')
    if (-not $days.ContainsKey($day)) {
        $days[$day] = @{ vids = [System.Collections.Generic.HashSet[string]]::new(); views = 0; clicks = @{}; src = @{} }
    }
    $bucket = $days[$day]

    if ($m.p) {
        $bucket.views++
        if ($m.v) { [void]$bucket.vids.Add([string]$m.v) }
        if ($m.s) {
            $s = [string]$m.s
            $bucket.src[$s] = [int]$bucket.src[$s] + 1
        }
    }
    if ($m.c) {
        $c = [string]$m.c
        $bucket.clicks[$c] = [int]$bucket.clicks[$c] + 1
    }

    $seen[$ev.id] = $day
    $new++
}

# ── 3. 오래된 메시지 id 정리 (2일 지난 건 다시 안 나타나므로 버림) ──
$cutoff = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd')
@($seen.Keys) | ForEach-Object { if ($seen[$_] -lt $cutoff) { $seen.Remove($_) } }

# ── 4. 로컬 상태 저장 ────────────────────────────────────────────
$stateOut = @{ days = @{}; seen = $seen; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
foreach ($k in $days.Keys) {
    $stateOut.days[$k] = @{
        vids   = @($days[$k].vids)
        views  = $days[$k].views
        clicks = $days[$k].clicks
        src    = $days[$k].src
    }
}
$stateOut | ConvertTo-Json -Depth 6 -Compress | Set-Content $statePath -Encoding UTF8

# ── 5. 공개용 집계 파일 (방문자 id 는 빼고 숫자만) ────────────────
$pub = [ordered]@{ updated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); days = [ordered]@{} }
foreach ($k in ($days.Keys | Sort-Object -Descending)) {
    $pub.days[$k] = [ordered]@{
        visitors = $days[$k].vids.Count
        views    = $days[$k].views
        clicks   = $days[$k].clicks
        src      = $days[$k].src
    }
}
$json = $pub | ConvertTo-Json -Depth 6
$prev = if (Test-Path $outPath) { Get-Content $outPath -Raw -Encoding UTF8 } else { '' }
$json | Set-Content $outPath -Encoding UTF8

Write-Log "polled=$($lines.Count) new=$new days=$($days.Count)"

# ── 6. 바뀐 게 있으면 배포 ───────────────────────────────────────
# updated 시각만 바뀐 경우까지 매번 커밋하면 히스토리가 지저분해지므로 새 이벤트가 있을 때만 푸시
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
