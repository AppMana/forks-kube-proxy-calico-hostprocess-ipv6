# Mocked tests for Wait-HnsNetworkReady (see README.md). Plain asserts, no
# Pester dependency. Exits nonzero on any failure. Each case bounds its own
# runtime; the blocking-query case is the 2026-07-07 production regression.
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\..\..\hostprocess\calico\kube-proxy\wait-hns.psm1'
Import-Module $modulePath -Force

$failures = 0
function Assert-Case {
    param([string]$Name, [scriptblock]$Body, [int]$MaxSeconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock $Body
    try {
        if (-not (Wait-Job $job -Timeout $MaxSeconds)) {
            Stop-Job $job
            Write-Host "FAIL  $Name (did not complete within ${MaxSeconds}s)"
            return $false
        }
        Receive-Job $job -ErrorAction Stop | Out-Null
        Write-Host ("PASS  {0} ({1:n1}s)" -f $Name, $sw.Elapsed.TotalSeconds)
        return $true
    } catch {
        Write-Host "FAIL  $Name ($_)"
        return $false
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

# State directory for cross-call mock state (query scriptblocks may run in
# child processes, so state must live on disk, mirroring the calico fork's
# mock-log approach).
$stateDir = Join-Path ([System.IO.Path]::GetTempPath()) ("waithns-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stateDir | Out-Null

$common = @"
Import-Module '$((Resolve-Path $modulePath).Path)' -Force
`$stateDir = '$stateDir'
"@

# Case 1: network already present -> returns promptly.
$case1 = [scriptblock]::Create($common + "`n" + @'
Wait-HnsNetworkReady -NetworkName Calico -QueryTimeoutSeconds 5 -PollIntervalSeconds 1 `
    -Query { param($sd) $true } -QueryArgumentList @($stateDir)
'@)

# Case 2: network appears on the third poll.
$case2 = [scriptblock]::Create($common + "`n" + @'
Wait-HnsNetworkReady -NetworkName Calico -QueryTimeoutSeconds 5 -PollIntervalSeconds 1 `
    -Query {
        param($sd)
        $f = Join-Path $sd 'case2'
        $n = 0; if (Test-Path $f) { $n = [int](Get-Content $f) }
        Set-Content $f ($n + 1)
        ($n + 1) -ge 3
    } -QueryArgumentList @($stateDir)
'@)

# Case 3 (2026-07-07 regression): the first query call blocks forever; later
# calls succeed. An unguarded loop never returns; the guarded wait must
# complete well under a minute.
$case3 = [scriptblock]::Create($common + "`n" + @'
Wait-HnsNetworkReady -NetworkName Calico -QueryTimeoutSeconds 5 -PollIntervalSeconds 1 `
    -Query {
        param($sd)
        $f = Join-Path $sd 'case3'
        $n = 0; if (Test-Path $f) { $n = [int](Get-Content $f) }
        Set-Content $f ($n + 1)
        if ($n -eq 0) { Start-Sleep 3600 }   # first call: hung HNS RPC
        $true
    } -QueryArgumentList @($stateDir)
'@)

if (-not (Assert-Case 'network already present' $case1 30)) { $failures++ }
if (-not (Assert-Case 'network appears after 3 polls' $case2 60)) { $failures++ }
if (-not (Assert-Case 'blocking query call is timed out and retried' $case3 45)) { $failures++ }

Remove-Item -Recurse -Force $stateDir -ErrorAction SilentlyContinue
if ($failures -gt 0) { Write-Host "$failures test(s) failed"; exit 1 }
Write-Host 'all tests passed'
