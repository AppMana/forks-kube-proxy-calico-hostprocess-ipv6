# AppMana kube-proxy HostProcess images

This fork builds patched Windows kube-proxy HostProcess images for AppMana's
Calico Windows/Linux k0s clusters.

Published multi-platform manifests:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.5-calico-hostprocess
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.6-calico-hostprocess
```

Version matrix:

```text
Kubernetes 1.34.x -> kube-proxy v1.34.6 -> Calico v3.29.6
Kubernetes 1.35.x -> kube-proxy v1.35.5 -> Calico v3.31.4
```

Each tag is a manifest list:

- `linux/amd64`: upstream `registry.k8s.io/kube-proxy:<version>`.
- `windows/amd64/ltsc2022`: AppMana patched HostProcess image.

Do not use `v1.34.6-appmana.post.3-calico-hostprocess` or
`v1.35.5-appmana.post.4-calico-hostprocess`. Those tags were published by a
workflow that allowed `git apply` to fail on the Windows runner, so their
Windows binaries did not include the stale-ELB reconciliation fix.

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
- L2Bridge `--source-vip` handling when DSR is disabled.
- IPv4-only fallback when the HNS network does not support IPv6.
- Mock coverage for unsupported HNS endpoint IP families.

The HostProcess start script also avoids deleting all HNS policy lists. It only
removes ELB policies, leaving Calico route and OutBoundNAT policies intact for
existing pods.

## Fixed issue: stale ClusterIP ELB state

The live AppMana failure seen during the Unity Windows pod outage was not a
generic Calico/BGP failure. Windows pods could reach CoreDNS pod endpoint IPs
directly, but DNS through the kube-dns ClusterIP timed out.

The failing shape on Windows was:

```text
pod -> CoreDNS endpoint IP:53       works
pod -> kube-dns ClusterIP:53        times out
HNS ELB PolicyList for ClusterIP    IsApplied=false
kube-proxy log                     "Policy already applied"
```

That points at Windows kube-proxy's ClusterIP/HNS ELB reconciliation. The
patched image correctly starts with `--enable-dsr=false` and
`--source-vip=<Calico_ep IPv4>`, and the ClusterIP policies are present in HNS.
The bad state is that HNS has the ELB PolicyList object but did not apply it to
VFP. In that state `Get-HnsPolicyList` shows `IsApplied: false`, while the
policy allocator data has `Tag: VFP ELB Policy Non Dsr` and an empty
`SourceVip`.

The important kube-proxy code path is:

```text
syncProxyRules()
  queries HNS endpoints and load balancers
  skips a service immediately when svcInfo.policyApplied is true
  only later calls hns.getLoadBalancer()/hns.updateLoadBalancer()
```

So kube-proxy can keep an in-memory `policyApplied=true` and skip a service
before comparing the current HNS load balancer state. Our previous test only
proved that ClusterIP load balancers do not request the unsupported
`ILB`/`LocalRoutedVIP` flag combination when SourceVIP is required. That does
not reproduce this outage on exact Kubernetes v1.34/v1.35 tags, because those
upstream call sites already omit those flags.

The post.5/post.6 images add a regression test that models an HNS ClusterIP
load balancer that exists but lost the desired SourceVIP/applied state while
kube-proxy still has `svcInfo.policyApplied=true`. The fix keeps the normal
`policyApplied` fast path when HNS still has the expected load balancer state,
but re-enters reconciliation when the cached HNS ClusterIP load balancer is
missing or has a stale SourceVIP.

Operationally, diagnose this before restarting random Calico components:

```powershell
$dnsVip = "10.152.184.10"
Get-HnsPolicyList |
  Where-Object { $_.Policies | Where-Object { $_.Type -eq "ELB" -and $_.VIP -eq $dnsVip } } |
  Select-Object ID, IsApplied, @{n="Policies";e={$_.Policies | ConvertTo-Json -Compress}}
```

If direct CoreDNS endpoint connectivity works but the ClusterIP policy has
`IsApplied=false`, roll the Windows kube-proxy image to the matching post.5 or
post.6 tag and re-check the HNS policy state.

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
        image: ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.6-calico-hostprocess
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

Use `v1.34.6-appmana.post.5-calico-hostprocess` for Kubernetes/k0s 1.34 and
Calico 3.29. Use `v1.35.5-appmana.post.6-calico-hostprocess` for
Kubernetes/k0s 1.35 and Calico 3.31.

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

The current `start.ps1` waits for the `Calico` HNS L2Bridge network and, when
DSR is disabled, `Calico_ep` so it can pass `--source-vip=<Calico_ep IPv4>`.
That ordering is not sufficient for a fresh kind/QEMU Windows node where
Calico HostProcess startup reaches the Kubernetes API through the in-cluster
service IP: kube-proxy waits for Calico HNS, while Calico waits for the service
IP path that kube-proxy would program. Treat `kube-proxy-windows` being
Kubernetes-Ready while it is still printing `Waiting for HNS network Calico to
be created...` as a bootstrap failure, not a validated datapath.

The Calico runbook preflights this by requiring `C:\CalicoWindows\nodename`,
HNS `Calico`, and HNS `Calico_ep` before running the health matrix.

## Build and publish

GitHub Actions builds on every push to `master` when the kube-proxy workflow,
patches, or HostProcess files change. It publishes:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.5-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.5-calico-hostprocess
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.6-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.6-calico-hostprocess
```

The tags without the `-windows-ltsc2022` suffix are the multi-platform
manifests used by k0s.
