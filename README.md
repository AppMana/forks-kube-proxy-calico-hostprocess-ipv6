# AppMana kube-proxy images

Windows kube-proxy with HNS reconciliation and L2Bridge service fixes, packaged
for Calico HostProcess deployments. Linux entries are unmodified upstream images.

## Use on k0s

For **k0s 1.37.2**, use:

```text
ghcr.io/appmana/kube-proxy:v1.37.2-appmana.post.1-calico-hostprocess
```

For **k0s 1.36.4 + Calico 3.32.2**, use:

```text
ghcr.io/appmana/kube-proxy:v1.36.4-appmana.post.14-calico-hostprocess
```

Each tag includes Linux amd64/arm64 and Windows Server 2022 amd64.
The Windows package includes kube-proxy and its startup/HNS readiness helpers.

Use the [Calico adapter](https://github.com/AppMana/forks-calico-windows-ipv6/tree/appmana-v3.32.2/windows-adapter)
to generate matching image settings for k0sctl. k0s manages the kube-proxy
DaemonSets; do not install duplicates. DSR defaults off for mixed-OS L2Bridge.
Windows IPv6 services additionally need Calico's Linux routing fall-through.

| Configuration | Result |
| --- | --- |
| Windows 2022/2025 native tests and three-platform package | [tested](https://github.com/AppMana/forks-kube-proxy-calico-hostprocess-ipv6/actions/runs/36345996183) |
| k0s 1.36.4, Linux + Windows 2022 BGP services | [tested](https://github.com/AppMana/k0s-containerd-calico-windows-integration/tree/ec4c527520826a7ab3555fd16ff94453fd508094) |
| k0s 1.37.2, Linux + Windows 2022 BGP services | unknown |
| Windows IPv6 ClusterIP without Linux fall-through | fails |
| Windows 2025 full lifecycle; Linux arm64 workloads | unknown |
| Equivalent full qualification of the older release lines | unknown |

The Windows binary is built from a pinned commit (`source_sha`) of the source
fork: `appmana/windows-kube-proxy-hns-ipv6-v1.37.2` is the v1.36.4 fork line
with the upstream v1.37.2 tag merged in. A release is published by pushing a
git tag equal to one matrix `image_tag` in the build configuration; only that
version is built.

[Source fork](https://github.com/AppMana/forks-kubernetes-kube-proxy-windows-ipv6) ·
[Build configuration and older versions](.github/workflows/build-kube-proxy-images.yml)
