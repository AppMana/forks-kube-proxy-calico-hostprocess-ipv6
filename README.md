# AppMana kube-proxy HostProcess images

This fork builds patched Windows kube-proxy HostProcess images for AppMana's
Calico Windows/Linux k0s clusters.

Published multi-platform manifests:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.1-calico-hostprocess
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.2-calico-hostprocess
```

Version matrix:

```text
Kubernetes 1.34.x -> kube-proxy v1.34.6 -> Calico v3.29.6
Kubernetes 1.35.x -> kube-proxy v1.35.5 -> Calico v3.31.4
```

Each tag is a manifest list:

- `linux/amd64`: upstream `registry.k8s.io/kube-proxy:<version>`.
- `windows/amd64/ltsc2022`: AppMana patched HostProcess image.

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
        image: ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.2-calico-hostprocess
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

Use `v1.34.6-appmana.post.1-calico-hostprocess` for Kubernetes/k0s 1.34 and
Calico 3.29. Use `v1.35.5-appmana.post.2-calico-hostprocess` for
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

Calico must create the `Calico` HNS L2Bridge network and `Calico_ep` host
endpoint before kube-proxy starts. The start script waits for both and passes
`--source-vip=<Calico_ep IPv4>` when running L2Bridge with DSR disabled.

## Build and publish

GitHub Actions builds on every push to `master` when the kube-proxy workflow,
patches, or HostProcess files change. It publishes:

```text
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.1-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.34.6-appmana.post.1-calico-hostprocess
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.2-calico-hostprocess-windows-ltsc2022
ghcr.io/appmana/kube-proxy:v1.35.5-appmana.post.2-calico-hostprocess
```

The tags without the `-windows-ltsc2022` suffix are the multi-platform
manifests used by k0s.
