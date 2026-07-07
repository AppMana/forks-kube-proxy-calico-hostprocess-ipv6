# Liveness probe for kube-proxy-windows. Detects the stale-ELB failure mode
# where HNS/VFP silently stops enforcing ClusterIP load balancers while
# kube-proxy's view (including live HCN sourceVip/flags) still looks correct:
# the May 8 and June 9, 2026 incidents on the AppMana cluster, where
# host/pod -> ClusterIP traffic timed out for ~1h while direct endpoint IPs
# worked, and only a kube-proxy container restart (whose start.ps1 wipes and
# rebuilds all ELB PolicyLists) repaired it.
#
# Logic: fail ONLY when the apiserver is reachable directly (so the apiserver
# itself is healthy and the node has connectivity) but the apiserver
# ClusterIP is not. Anything else - apiserver down, node offline - exits 0 so
# kube-proxy is not restart-looped for failures it cannot fix.
#
# Environment:
#   KUBEPROXY_HEALTH_CLUSTERIP       apiserver ClusterIP (e.g. 10.152.184.1);
#                                    defaults to KUBERNETES_SERVICE_HOST (which
#                                    the kubelet injects into every container);
#                                    probe is a no-op when neither is set
#   KUBEPROXY_HEALTH_CLUSTERIP_PORT  default 443
#   KUBEPROXY_HEALTH_DIRECT          direct apiserver host:port; defaults to the
#                                    server in the mounted kube-proxy kubeconfig
$ErrorActionPreference = 'SilentlyContinue'

$vip = $env:KUBEPROXY_HEALTH_CLUSTERIP
if ([string]::IsNullOrWhiteSpace($vip)) {
    $vip = $env:KUBERNETES_SERVICE_HOST
}
if ([string]::IsNullOrWhiteSpace($vip)) {
    Write-Output 'health-check: no KUBEPROXY_HEALTH_CLUSTERIP or KUBERNETES_SERVICE_HOST; skipping'
    exit 0
}
$vipPort = 443
if (-not [string]::IsNullOrWhiteSpace($env:KUBEPROXY_HEALTH_CLUSTERIP_PORT)) {
    $vipPort = [int]$env:KUBEPROXY_HEALTH_CLUSTERIP_PORT
}

function Test-Tcp([string]$TargetHost, [int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(4000)) { $client.Close(); return $false }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

if (Test-Tcp $vip $vipPort) {
    exit 0
}

# ClusterIP failed - only report unhealthy if the apiserver is fine directly.
$direct = $env:KUBEPROXY_HEALTH_DIRECT
if ([string]::IsNullOrWhiteSpace($direct)) {
    $kubeconfig = Join-Path $env:CONTAINER_SANDBOX_MOUNT_POINT 'var/lib/kube-proxy/kubeconfig.conf'
    $serverLine = (Get-Content $kubeconfig | Select-String -Pattern 'server:\s*https://(\S+)') | Select-Object -First 1
    if ($serverLine) { $direct = $serverLine.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($direct)) {
    Write-Output 'health-check: no direct apiserver endpoint known; treating ClusterIP failure as inconclusive'
    exit 0
}
$directHost, $directPort = $direct -split ':', 2
if ([string]::IsNullOrWhiteSpace($directPort)) { $directPort = '443' }

if (Test-Tcp $directHost ([int]$directPort)) {
    Write-Output ("health-check: UNHEALTHY - direct apiserver " + $direct + " reachable but ClusterIP " + $vip + ":" + $vipPort + " is not (stale HNS ELB state)")
    exit 1
}

Write-Output ("health-check: apiserver unreachable directly (" + $direct + "); ClusterIP failure inconclusive")
exit 0
