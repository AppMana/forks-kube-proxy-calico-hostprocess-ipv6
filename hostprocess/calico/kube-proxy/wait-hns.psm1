# Wait-HnsNetworkReady: blocks until the named HNS network exists.
#
# The query runs with an injectable scriptblock so tests can mock HNS behavior
# (see hack/appmana/tests/). The default query imports hns.psm1 and calls
# Get-HnsNetwork.
function Wait-HnsNetworkReady {
    param(
        [Parameter(Mandatory)] [string]$NetworkName,
        [scriptblock]$Query,
        [object[]]$QueryArgumentList,
        [string]$HnsModulePath,
        [int]$QueryTimeoutSeconds = 15,
        [int]$PollIntervalSeconds = 1
    )
    if (-not $Query) {
        $Query = {
            param($name, $modulePath)
            Import-Module $modulePath -Force
            [bool](Get-HnsNetwork | Where-Object Name -EQ $name)
        }
        $QueryArgumentList = @($NetworkName, $HnsModulePath)
    }

    # Each query runs in a disposable child job with a hard timeout: a
    # Get-HnsNetwork call issued while the HNS service is restarting (node
    # reboot, kubelet swap) can block forever inside the RPC, which
    # permanently froze an unguarded in-process loop on all three Windows
    # nodes on 2026-07-07 — the retry never ran because the first call never
    # returned.
    while ($true) {
        $job = Start-Job -ScriptBlock $Query -ArgumentList $QueryArgumentList
        if (Wait-Job $job -Timeout $QueryTimeoutSeconds) {
            $found = [bool](Receive-Job $job -ErrorAction SilentlyContinue)
            Remove-Job $job -Force
            if ($found) { return }
        } else {
            Write-Host "HNS query timed out after ${QueryTimeoutSeconds}s (HNS restarting?); retrying with a fresh process."
            Stop-Job $job
            Remove-Job $job -Force
        }
        Start-Sleep $PollIntervalSeconds
    }
}

Export-ModuleMember -Function Wait-HnsNetworkReady
