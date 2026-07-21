# 통계 수집기 스케줄러
#
# 이 PC 계정은 작업 스케줄러 등록 권한이 없어서(schtasks: Access denied),
# blockmedia-telegram / btc-signal-bot 과 같은 방식으로 로그온 시 숨김 실행되는
# 무한 루프를 쓴다. 시작 등록: Startup 폴더의 start-linkbio-stats.vbs
#
# ntfy 무료 채널은 12시간만 보관하므로 3시간 주기로 수집한다.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$collector = Join-Path $root 'collect-stats.ps1'
$logPath = Join-Path $root 'collect.log'

# 중복 실행 방지 — VBS 가 두 번 뜨거나 수동 실행이 겹쳐도 하나만 살아남게
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\LinkBioStatsLoop', [ref]$created)
if (-not $created) { exit 0 }

function Write-Log($msg) {
    Add-Content -Path $logPath -Value ("[{0}] LOOP: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}

Write-Log "started (pid $PID)"
while ($true) {
    try {
        & $collector
    } catch {
        Write-Log "collector failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 10800   # 3시간
}
