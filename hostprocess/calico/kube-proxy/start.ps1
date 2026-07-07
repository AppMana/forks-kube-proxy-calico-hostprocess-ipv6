# Copyright (c) 2020 Tigera, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Modified from https://github.com/projectcalico/node
$NetworkName = "Calico"
if (test-path env:KUBEPROXY_PATH){ 
    # used for CI flows
    $kproxy = $env:KUBEPROXY_PATH
}else {
    $kproxy = "$env:CONTAINER_SANDBOX_MOUNT_POINT/kube-proxy/kube-proxy.exe"
}
ipmo -Force .\hns.psm1

Write-Host "Running kub-proxy service."

# Now, wait for the Calico network to be created. Each query runs in a
# disposable child process with a hard timeout: a Get-HnsNetwork call issued
# while the HNS service is restarting (node reboot, kubelet swap) can block
# forever inside the RPC, which permanently froze this loop on all three
# Windows nodes on 2026-07-07 — the in-process 1s retry never got a chance
# to retry because the first call never returned.
Write-Host "Waiting for HNS network $NetworkName to be created..."
while ($true) {
    $query = Start-Job -ScriptBlock {
        param($moduleDir, $name)
        Import-Module (Join-Path $moduleDir 'hns.psm1') -Force
        [bool](Get-HnsNetwork | Where-Object Name -EQ $name)
    } -ArgumentList $PSScriptRoot, $NetworkName
    if (Wait-Job $query -Timeout 15) {
        $found = Receive-Job $query
        Remove-Job $query -Force
        if ($found) { break }
    } else {
        Write-Host "HNS query timed out after 15s (HNS restarting?); retrying with a fresh process."
        Stop-Job $query; Remove-Job $query -Force
    }
    Start-Sleep 1
}
Write-Host "HNS network $NetworkName found."

# Determine the kube-proxy version.
$kubeProxyVer = $(Invoke-Expression "$kproxy --version")
echo "kubeproxy version $kubeProxyVer"
$kubeProxyGE114 = $false
if ($kubeProxyVer -match "v([0-9])\.([0-9]+)") {
    $major = $Matches.1 -as [int]
    $minor = $Matches.2 -as [int]
    $kubeProxyGE114 = ($major -GT 1 -OR $major -EQ 1 -AND $minor -GE 14)
}

# Mixed Windows/Linux clusters need DSR off because Windows DSR breaks
# cross-node ClusterIP routing when the backend resolves to a Linux pod.
# DSR is DISABLED BY DEFAULT since post.11: the DaemonSet may be rendered by
# an orchestrator that sets no env at all (k0s 1.36 renders its own
# kube-proxy-windows DaemonSet with only NODENAME/POD_IP), so the safe
# behavior must not depend on env vars being present. Set
# KUBEPROXY_ENABLE_DSR=true to opt in (requires 2019 with KB4580390,
# Oct 2020). KUBEPROXY_DISABLE_DSR=true is still honored for backward
# compatibility and wins over the enable flag.
$PlatformSupportDSR = $false
if ($env:KUBEPROXY_ENABLE_DSR -EQ "true") {
    $PlatformSupportDSR = $true
    Write-Host "DSR enabled via KUBEPROXY_ENABLE_DSR=true env var."
}
if ($env:KUBEPROXY_DISABLE_DSR -EQ "true") {
    $PlatformSupportDSR = $false
    Write-Host "DSR disabled via KUBEPROXY_DISABLE_DSR=true env var."
}

# This is a workaround since the go-client doesn't know about the path $env:CONTAINER_SANDBOX_MOUNT_POINT
# go-client is going to be address in a future release:
#   https://github.com/kubernetes/kubernetes/pull/104490
# We could address this in kubeamd as well: 
#   https://github.com/kubernetes/kubernetes/blob/9f0f14952c51e7a5622eac05c541ba20b5821627/cmd/kubeadm/app/phases/addons/proxy/manifests.go
Write-Host "Write files so the kubeconfig points to correct locations"
mkdir -force /var/lib/kube-proxy/
((Get-Content -path $env:CONTAINER_SANDBOX_MOUNT_POINT/var/lib/kube-proxy/kubeconfig.conf -Raw) -replace '/var',"$($env:CONTAINER_SANDBOX_MOUNT_POINT)/var") | Set-Content -Path $env:CONTAINER_SANDBOX_MOUNT_POINT/var/lib/kube-proxy/kubeconfig-win.conf
cp $env:CONTAINER_SANDBOX_MOUNT_POINT/var/lib/kube-proxy/kubeconfig-win.conf /var/lib/kube-proxy/kubeconfig.conf

# Build up the arguments for starting kube-proxy.
$argList = @(`
    "--hostname-override=$env:NODENAME", `
    "--v=4",`
    "--proxy-mode=kernelspace",`
    "--kubeconfig=$env:CONTAINER_SANDBOX_MOUNT_POINT/var/lib/kube-proxy/kubeconfig-win.conf"`
)
$extraFeatures = @()

if ($kubeProxyGE114 -And $PlatformSupportDSR) {
    Write-Host "Requires 2019 with KB4580390 (Oct 2020)"
    $extraFeatures += "WinDSR=true"
    $argList += "--enable-dsr=true"
} else {
    Write-Host "DSR feature is not supported or disabled."
    $argList += "--enable-dsr=false"
}

$network = (Get-HnsNetwork | ? Name -EQ $NetworkName)
if ($network.Type -EQ "Overlay") {
    if (-NOT $kubeProxyGE114) {
        throw "Overlay network requires kube-proxy >= v1.14.  Detected $kubeProxyVer."
    }
    # This is a VXLAN network, kube-proxy needs to know the source IP to use for SNAT operations.
    Write-Host "Detected VXLAN network, waiting for Calico host endpoint to be created..."
    while (-Not (Get-HnsEndpoint | ? Name -EQ "Calico_ep")) {
        Start-Sleep 1
    }
    Write-Host "Host endpoint found."
    $sourceVip = (Get-HnsEndpoint | ? Name -EQ "Calico_ep").IpAddress
    $argList += "--source-vip=$sourceVip"
    $extraFeatures += "WinOverlay=true"
}

# L2Bridge with DSR off must not pass Calico_ep as --source-vip. The patched
# kube-proxy binary derives the SourceVIP per proxier family from the node IP
# when winkernel.sourceVip is empty. Passing Calico_ep here is IPv4-only and
# causes the IPv6 proxier to submit mixed-family HCN load balancers.
if ($network.Type -EQ "L2Bridge" -AND -NOT $PlatformSupportDSR) {
    Write-Host "Detected L2Bridge with DSR disabled; leaving --source-vip unset for kube-proxy."
}

if ($extraFeatures.Length -GT 0) {
    $featuresStr = $extraFeatures -join ","
    $argList += "--feature-gates=$featuresStr"
    Write-Host "Enabling feature gates: $extraFeatures."
}

# kube-proxy doesn't handle resync if there are pre-existing ELB policies, clean
# THEM out before (re)starting kube-proxy. Wipe ELB-type only — wiping ALL
# PolicyLists destroys non-ELB Calico-managed policies (route encapsulation,
# OutBoundNAT exception lists, etc.) that pods on this node depend on for their
# IPv4 default gateway. Symptom: fresh pods get pod IP but no IPv4 default
# route, so pod->ClusterIP and pod->WAN both silently time out (this is what
# nuked Unity pods on appmana-003 and -005 on 2026-05-08).
$policyLists = Get-HnsPolicyList | Where-Object {
    $_.Policies | Where-Object { $_.Type -eq 'ELB' }
}
if ($policyLists) {
    $policyLists | Remove-HnsPolicyList
}

Write-Host "Start to run $kproxy $argList"
# We'll also pick up a network name env var from the Calico config file.  Override it
# since the value in the config file may be a regex.
$env:KUBE_NETWORK=$NetworkName

# Since post.11 kube-proxy runs as a child process with an in-script stale-ELB
# watchdog instead of a DaemonSet livenessProbe: the DaemonSet may be rendered
# by an orchestrator (k0s 1.36) whose template carries no probe, so the
# restart-on-stale-ELB behavior has to live inside the container. The watchdog
# reuses health-check.ps1 (which defaults its probe VIP to
# KUBERNETES_SERVICE_HOST); five consecutive failures kill kube-proxy and exit
# nonzero so the kubelet restarts the container and start.ps1 wipes the stale
# ELB policies on the way back up.
$proc = Start-Process -FilePath $kproxy -ArgumentList $argList -NoNewWindow -PassThru
$healthScript = Join-Path $PSScriptRoot 'health-check.ps1'
$consecutiveFailures = 0
while ($true) {
    Start-Sleep -Seconds 60
    if ($proc.HasExited) {
        Write-Host "kube-proxy exited with code $($proc.ExitCode)."
        exit 1
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $healthScript | Out-Null
    if ($LASTEXITCODE -NE 0) {
        $consecutiveFailures++
        Write-Host "health check failed ($consecutiveFailures consecutive)."
    } else {
        $consecutiveFailures = 0
    }
    if ($consecutiveFailures -GE 5) {
        Write-Host "health check failed 5 consecutive times; restarting kube-proxy."
        Stop-Process -Id $proc.Id -Force
        exit 1
    }
}
