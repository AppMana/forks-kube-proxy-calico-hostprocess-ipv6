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

# Now, wait for the Calico network to be created.
Write-Host "Waiting for HNS network $NetworkName to be created..."
while (-Not (Get-HnsNetwork | ? Name -EQ $NetworkName)) {
    Write-Debug "Still waiting for HNS network..."
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

# Determine the windows version and build number for DSR support.
# requires 2019 with KB4580390 (Oct 2020)
$PlatformSupportDSR = $true

# Mixed Windows/Linux clusters need DSR off because Windows DSR breaks
# cross-node ClusterIP routing when the backend resolves to a Linux pod.
# Set KUBEPROXY_DISABLE_DSR=true on the DaemonSet to opt out.
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

# L2Bridge with DSR off also needs --source-vip. Without it kube-proxy registers
# HCN ELB policies for ClusterIPs but HNS computes a NAT pool against an
# unresolvable source IP and silently sets IsApplied=false. Result: pod ->
# ClusterIP TCP times out for every service. Upstream's existing block above
# only covers Overlay networks; mirror the same discovery for L2Bridge non-DSR.
if ($network.Type -EQ "L2Bridge" -AND -NOT $PlatformSupportDSR) {
    Write-Host "Detected L2Bridge with DSR disabled, waiting for Calico host endpoint to be created..."
    while (-Not (Get-HnsEndpoint | ? Name -EQ "Calico_ep")) {
        Start-Sleep 1
    }
    Write-Host "Host endpoint found."
    $sourceVip = (Get-HnsEndpoint | ? Name -EQ "Calico_ep").IpAddress
    $argList += "--source-vip=$sourceVip"
    Write-Host "Using --source-vip=$sourceVip"
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
Invoke-Expression "$kproxy $argList"
