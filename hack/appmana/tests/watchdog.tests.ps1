# Behavioral tests for the watchdog loop shipped in start.ps1. The loop is
# executed verbatim in an isolated child PowerShell process with only its
# external commands replaced. This keeps the test coupled to the production
# counter, reset, logging, stop, and exit behavior without starting kube-proxy.
$ErrorActionPreference = 'Stop'

$startPath = Join-Path $PSScriptRoot '..\..\..\hostprocess\calico\kube-proxy\start.ps1'
$startSource = Get-Content -LiteralPath $startPath -Raw
$loopMarker = '$proc = Start-Process -FilePath $kproxy -ArgumentList $argList -NoNewWindow -PassThru'
$loopOffset = $startSource.IndexOf($loopMarker, [System.StringComparison]::Ordinal)
if ($loopOffset -lt 0) { throw 'production watchdog loop marker not found' }
$watchdogLoop = $startSource.Substring($loopOffset)

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('kube-proxy-watchdog-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
$runnerPath = Join-Path $tempDir 'runner.ps1'
$callLog = Join-Path $tempDir 'calls.log'
$stopLog = Join-Path $tempDir 'stops.log'

$runnerPreamble = @'
param(
    [Parameter(Mandatory = $true)][string]$Sequence,
    [Parameter(Mandatory = $true)][string]$CallLog,
    [Parameter(Mandatory = $true)][string]$StopLog
)
$ErrorActionPreference = 'Stop'
$script:results = @($Sequence -split ',' | ForEach-Object {
    $fields = $_ -split ':', 2
    [pscustomobject]@{ ExitCode = [int]$fields[0]; Output = $fields[1] }
})
$script:callIndex = 0
$script:fakeProcess = [pscustomobject]@{ HasExited = $false; ExitCode = 0; Id = 4242 }

function Start-Process { return $script:fakeProcess }
function Start-Sleep { }
function Stop-Process {
    param([int]$Id, [switch]$Force)
    Add-Content -LiteralPath $StopLog -Value "$Id|$Force"
}
function global:powershell.exe {
    if ($script:callIndex -ge $script:results.Count) {
        throw 'watchdog invoked the health check more times than expected'
    }
    $result = $script:results[$script:callIndex]
    $script:callIndex++
    Add-Content -LiteralPath $CallLog -Value $script:callIndex
    $global:LASTEXITCODE = $result.ExitCode
    if ($result.ExitCode -eq 0 -and $script:callIndex -eq $script:results.Count) {
        $script:fakeProcess.HasExited = $true
    }
    Write-Output $result.Output
}

$kproxy = 'mock-kube-proxy.exe'
$argList = @()
'@

Set-Content -LiteralPath $runnerPath -Value ($runnerPreamble + [Environment]::NewLine + $watchdogLoop)

$failures = 0
function Invoke-WatchdogCase {
    param([string]$Name, [string]$Sequence)
    Remove-Item -LiteralPath $callLog, $stopLog -Force -ErrorAction SilentlyContinue
    $output = & pwsh -NoProfile -File $runnerPath -Sequence $Sequence -CallLog $callLog -StopLog $stopLog 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        Name = $Name
        Output = $output
        ExitCode = $exitCode
        Calls = if (Test-Path $callLog) { @(Get-Content -LiteralPath $callLog) } else { @() }
        Stops = if (Test-Path $stopLog) { @(Get-Content -LiteralPath $stopLog) } else { @() }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "PASS  $Message"; return }
    Write-Host "FAIL  $Message"
    $script:failures++
}

try {
    $fiveFailures = Invoke-WatchdogCase 'five failures' '1:probe-detail-1,1:probe-detail-2,1:probe-detail-3,1:probe-detail-4,1:probe-detail-5'
    Assert-True ($fiveFailures.ExitCode -eq 1) 'five consecutive failures exit nonzero'
    Assert-True ($fiveFailures.Calls.Count -eq 5) 'five consecutive failures invoke exactly five probes'
    Assert-True ($fiveFailures.Stops.Count -eq 1) 'five consecutive failures stop kube-proxy exactly once'
    foreach ($n in 1..5) {
        Assert-True ($fiveFailures.Output -match "probe-detail-$n") "failed probe $n preserves its diagnostic output"
    }
    Assert-True ($fiveFailures.Output -match 'health check failed 5 consecutive times; restarting kube-proxy\.') 'five-failure restart message is unchanged'

    $reset = Invoke-WatchdogCase 'healthy reset' '1:failure-a,1:failure-b,0:healthy-detail,1:failure-c,1:failure-d,1:failure-e,1:failure-f,1:failure-g'
    Assert-True ($reset.ExitCode -eq 1) 'failure sequence after a healthy probe still exits nonzero'
    Assert-True ($reset.Calls.Count -eq 8) 'healthy probe resets the consecutive-failure counter'
    Assert-True ($reset.Stops.Count -eq 1) 'reset sequence stops kube-proxy exactly once'
    Assert-True ($reset.Output -notmatch 'healthy-detail') 'healthy probe output remains quiet'

    $healthy = Invoke-WatchdogCase 'healthy quiet' '0:healthy-only-detail'
    Assert-True ($healthy.Calls.Count -eq 1) 'healthy path invokes one probe before mocked child exit'
    Assert-True ($healthy.Stops.Count -eq 0) 'healthy path does not stop kube-proxy'
    Assert-True ($healthy.Output -notmatch 'healthy-only-detail') 'healthy path remains quiet'
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures test(s) failed"; exit 1 }
Write-Host 'all tests passed'
