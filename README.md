# AppMana kube-proxy images

Windows kube-proxy with HNS reconciliation and L2Bridge service fixes, packaged
for Calico HostProcess deployments. Linux entries are unmodified upstream images.

## Use on k0s

For **k0s 1.36.4 + Calico 3.32.2**, use:

```text
ghcr.io/appmana/kube-proxy:v1.36.4-appmana.post.14-calico-hostprocess
```

This tag includes Linux amd64/arm64 and Windows Server 2022 amd64.
The Windows package includes kube-proxy and its startup/HNS readiness helpers.

Use the [Calico adapter](https://github.com/AppMana/forks-calico-windows-ipv6/tree/appmana-v3.32.2/windows-adapter)
to generate matching image settings for k0sctl. k0s manages the kube-proxy
DaemonSets; do not install duplicates. DSR defaults off for mixed-OS L2Bridge.
Windows IPv6 services additionally need Calico's Linux routing fall-through.

| Configuration | Result |
| --- | --- |
| Windows 2022/2025 native tests and three-platform package | [tested](https://github.com/AppMana/forks-kube-proxy-calico-hostprocess-ipv6/actions/runs/36345996183) |
| k0s 1.36.4, Linux + Windows 2022 BGP services | [tested](https://github.com/AppMana/k0s-containerd-calico-windows-integration/tree/ec4c527520826a7ab3555fd16ff94453fd508094) |
| Windows IPv6 ClusterIP without Linux fall-through | fails |
| Windows 2025 full lifecycle; Linux arm64 workloads | unknown |
| Equivalent full qualification of the older release lines | unknown |

[Source fork](https://github.com/AppMana/forks-kubernetes-kube-proxy-windows-ipv6) ·
[Build configuration and older versions](.github/workflows/build-kube-proxy-images.yml)
