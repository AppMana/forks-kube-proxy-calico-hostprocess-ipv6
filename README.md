# AppMana kube-proxy HostProcess images

This repository builds patched Windows kube-proxy HostProcess images for
AppMana's Calico Windows/Linux k0s clusters. The public tags are multi-platform
manifests with upstream Linux kube-proxy and AppMana-patched Windows kube-proxy.

Published manifests:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.12-calico-hostprocess
  sha256:4257c386e577c855443480583fb2564e5f0e2319c436f4ae126146b6012fd033

ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.8-calico-hostprocess
  sha256:ae693837fc36f98f313aab545fca9799756e94228263d5f586c162e4ee69ffaf
```

Version matrix:

```text
Kubernetes 1.34.x -> kube-proxy v1.34.6 -> Calico v3.29.6
Kubernetes 1.35.x -> kube-proxy v1.35.5 -> Calico v3.31.4
```

Each tag contains:

- `linux/amd64`: upstream `registry.k8s.io/kube-proxy:<version>`.
- `windows/amd64/ltsc2022`: AppMana patched HostProcess image.

## Do not use older post tags

Do not use `v1.34.6-appmana.post.3-calico-hostprocess` or
`v1.35.5-appmana.post.4-calico-hostprocess`. Those tags were published by a
workflow that allowed `git apply` to fail on the Windows runner, so the Windows
binaries did not include the stale-ELB reconciliation fix.

Do not use `v1.34.6-appmana.post.5-calico-hostprocess` or
`v1.35.5-appmana.post.6-calico-hostprocess` for L2Bridge clusters. Those tags
still leave `winkernel.sourceVip` empty when kube-proxy is not running overlay
mode, so fresh IPv4 ClusterIP load balancers are created without SourceVIP.

Do not use post.10/post.11-style images for Windows ClusterIP validation. They
fixed part of SourceVIP selection but left ClusterIP HNS load balancers as
non-ILB, which still breaks pod-to-service traffic.

## What is patched

The Windows kube-proxy patches are generated from the matching branches in
`AppMana/forks-kubernetes-kube-proxy-windows-ipv6`:

```text
appmana/windows-kube-proxy-hns-ipv6-v1.34.x
appmana/windows-kube-proxy-hns-ipv6-v1.35.x
```

The workflow applies the version-specific patch file, runs
`go test ./pkg/proxy/winkernel/...`, builds `kube-proxy.exe`, and packages it in
the HostProcess image.

The Windows fixes cover:

- Stable HCN load balancer identity that includes IP family.
- L2Bridge SourceVIP selection when DSR is disabled.
- IPv6 SourceVIP selection from the Windows node management ULA.
- IPv4-only fallback when the HNS network does not support IPv6.
- ClusterIP HNS load balancers with `ILB: true` and `LocalRoutedVIP: false`.
- Reconciliation for stale HNS ClusterIP state when kube-proxy's cached
  `policyApplied` state no longer matches HNS.
- Mock coverage for unsupported HNS endpoint IP families and stale HNS policy
  state.

The HostProcess start script also avoids deleting all HNS policy lists. It only
removes ELB policies, leaving Calico route and OutBoundNAT policies intact for
existing pods.

For L2Bridge with DSR disabled, `hostprocess/calico/kube-proxy/start.ps1`
leaves `--source-vip` unset. The patched kube-proxy then derives SourceVIP per
IP family from the Windows node management addresses. Do not pass `Calico_ep`;
that endpoint is IPv4-only and breaks mixed IPv4/IPv6 selection.

## Fixed issue: Windows pod-to-ClusterIP failure

The live AppMana failure seen during the Unity Windows pod outage was not a
generic Calico/BGP failure and was not fixed by DNS policy changes. Windows pods
could reach CoreDNS pod endpoint IPs directly, but DNS through the kube-dns
ClusterIP timed out.

The failing shape was:

```text
pod -> CoreDNS endpoint IP:53       works
pod -> kube-dns ClusterIP:53        times out
pod -> ingress ClusterIP:443        times out
Unity log                           "Peer could not reach https://signaling-h2.appmana.com:443"
HNS ELB PolicyList for ClusterIP    ILB=false or stale/applied state mismatch
```

`signaling-h2.appmana.com` resolves inside the cluster to the ingress ClusterIP
`10.152.184.99`, so Unity pod registration requires the Windows ClusterIP path.
When that path fails, the signaling server eventually reports no usable hosts
because Windows pods never registered.

The correct HNS policy shape for a ClusterIP is:

```text
Type: ELB
VIP: 10.152.184.10
ExternalPort/InternalPort: 53
ILB: true
IsDSR: false
LocalRoutedVIP: false
SourceVIP: 10.2.0.3
```

For IPv6 ClusterIPs, `SourceVIP` must be the node's management IPv6 ULA.

Operationally, diagnose this with a functional check, not `IsApplied`:

```powershell
# Stale-ELB state = direct endpoint works, ClusterIP does not.
Test-NetConnection <endpoint-pod-or-node-ip> -Port <port>   # expect True
Test-NetConnection <service-cluster-ip> -Port <port>        # broken when False
```

From a Windows pod:

```powershell
Resolve-DnsName signaling-h2.appmana.com -DnsOnly
Test-NetConnection 10.152.184.10 -Port 53 -InformationLevel Quiet
Test-NetConnection signaling-h2.appmana.com -Port 443 -InformationLevel Quiet
```

Expected AppMana production values:

```text
signaling-h2.appmana.com -> 10.152.184.99
10.152.184.10:53       -> True
signaling-h2:443       -> True
```

WARNING: `Get-HnsPolicyList` reports `IsApplied=false` for every PolicyList on
HEALTHY Windows Server 2022 nodes (verified 2026-06-10 on three working
production nodes: 236/236 policies `IsApplied=false` while all ClusterIPs
worked). It is not a usable health signal through the PowerShell module; do
not base remediation on it.

Known residual gap (June 9, 2026 incident): after a node reboot, host and pod
traffic to ClusterIPs timed out for ~1h while direct endpoint IPs worked, on a
kube-proxy already carrying the reconciliation patch. Live HCN state
(sourceVip, flags) matched the desired state, so reconciliation never
re-fired; VFP had silently dropped enforcement. The state cleared when the
kube-proxy pods restarted, because `start.ps1` wipes and rebuilds all ELB
PolicyLists at startup. Until the VFP-level divergence is detectable from the
HCN API, the mitigation is the liveness probe below, which converts that
hour-long outage into an automatic container restart after a few minutes.

### Stale-ELB liveness probe

`health-check.ps1` (shipped in the image) fails ONLY when the apiserver is
reachable at its direct endpoint but not at its ClusterIP — the stale-ELB
signature. Apiserver-down and node-offline conditions exit healthy so
kube-proxy is not restart-looped for failures it cannot fix.

```yaml
        env:
        - name: KUBEPROXY_HEALTH_CLUSTERIP
          value: "10.152.184.1"     # apiserver ClusterIP for this cluster
        livenessProbe:
          exec:
            command:
            - powershell.exe
            - -NoProfile
            - -File
            - "$env:CONTAINER_SANDBOX_MOUNT_POINT/kube-proxy/health-check.ps1"
          initialDelaySeconds: 120
          periodSeconds: 30
          failureThreshold: 5
          timeoutSeconds: 15
```

## Windows DaemonSet

Use the image matching the Kubernetes/k0s minor version:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-proxy-windows
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: kube-proxy-windows
  template:
    metadata:
      labels:
        k8s-app: kube-proxy-windows
    spec:
      serviceAccountName: kube-proxy
      hostNetwork: true
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
      - operator: Exists
      securityContext:
        windowsOptions:
          hostProcess: true
          runAsUserName: "NT AUTHORITY\\system"
      containers:
      - name: kube-proxy
        image: ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.8-calico-hostprocess
        args:
        - "$env:CONTAINER_SANDBOX_MOUNT_POINT/kube-proxy/start.ps1"
        workingDir: "$env:CONTAINER_SANDBOX_MOUNT_POINT/kube-proxy/"
        env:
        - name: NODENAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: KUBEPROXY_DISABLE_DSR
          value: "true"
        volumeMounts:
        - mountPath: /var/lib/kube-proxy
          name: kube-proxy
      volumes:
      - name: kube-proxy
        configMap:
          name: kube-proxy
```

Use `v1.34.6-appmana.post.12-calico-hostprocess` for Kubernetes/k0s 1.34 and
Calico 3.29. Use `v1.35.5-appmana.post.8-calico-hostprocess` for
Kubernetes/k0s 1.35 and Calico 3.31.

Production 1.34 currently uses the Harbor Windows-only image by digest through
GitOps:

```text
harbor.appmana.com/appmana-shared/kube-proxy:v1.34.6-appmana.post.12-calico-hostprocess-windows-ltsc2022@sha256:ca3d82d26c5b0bc4c4101502eef85aa3caf986ce78380e73dab16df8cf9a1030
```

## BGP and DSR requirements

These images are intended for Calico `windows-bgp` / HNS L2Bridge clusters.

Set:

```yaml
env:
- name: KUBEPROXY_DISABLE_DSR
  value: "true"
```

Mixed Linux/Windows ClusterIP traffic must run with DSR disabled. With DSR
enabled, a Windows pod connecting to a Linux-backed ClusterIP can receive the
reply directly from the Linux pod IP instead of the ClusterIP, and Windows drops
the TCP stream.

The Calico runbook preflights this by requiring `C:\CalicoWindows\nodename`,
HNS `Calico`, and HNS `Calico_ep` before running the health matrix. Treat
`kube-proxy-windows` being Kubernetes-Ready while it is still printing
`Waiting for HNS network Calico to be created...` as a bootstrap failure, not a
validated datapath.

## Build and publish

GitHub Actions builds on every push to `master` when the kube-proxy workflow,
patches, or HostProcess files change. It publishes:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.12-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.12-calico-hostprocess
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.8-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.8-calico-hostprocess
```

The tags without the `-windows-ltsc2022` suffix are the multi-platform
manifests used by k0s.
