#!/usr/bin/env bash
# Build the kube-proxy Calico HostProcess Windows image.
#
# Bases on nanoserver and pre-fetches kube-proxy.exe + hns.psm1 into dist/
# so we don't depend on:
#   - The windows-host-process-containers-base-image (broken on WS2022 23H2,
#     hcsshim::ImportLayer 0x3f1)
#   - A Linux multi-stage curl step that the Windows-only buildkit can't satisfy
#
# Build runs on the Linux buildkit by default (one less moving part); pass
# BUILDER=calico-windows-builder to use the native Windows builder.
set -euo pipefail

K8S_VERSION="${1:-v1.34.6}"
IMAGE="${2:-harbor.appmana.com/appmana-shared/kube-proxy:${K8S_VERSION}-calico-hostprocess}"

cd "$(dirname "$0")"

mkdir -p dist
if [ ! -f dist/kube-proxy.exe ] || [ ! -f dist/.k8sversion ] || [ "$(cat dist/.k8sversion)" != "${K8S_VERSION}" ]; then
    echo "fetching kube-proxy.exe ${K8S_VERSION}..."
    rm -f dist/kube-proxy.exe dist/kube-proxy.exe.sha256
    curl -fLo dist/kube-proxy.exe "https://dl.k8s.io/${K8S_VERSION}/bin/windows/amd64/kube-proxy.exe"
    curl -fLo dist/kube-proxy.exe.sha256 "https://dl.k8s.io/${K8S_VERSION}/bin/windows/amd64/kube-proxy.exe.sha256"
    expected=$(cat dist/kube-proxy.exe.sha256)
    actual=$(sha256sum dist/kube-proxy.exe | cut -d' ' -f1)
    if [ "$expected" != "$actual" ]; then
        echo "kube-proxy.exe sha256 mismatch: expected $expected, got $actual" >&2
        exit 1
    fi
    echo "${K8S_VERSION}" > dist/.k8sversion
fi

if [ ! -f dist/hns.psm1 ]; then
    echo "fetching hns.psm1..."
    curl -fLo dist/hns.psm1 https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1
fi

BUILDER="${BUILDER:-lin-multi}"

echo "building $IMAGE on $BUILDER..."
docker buildx build \
    --builder "$BUILDER" \
    --platform windows/amd64 \
    --build-arg WINDOWS_VERSION=ltsc2022 \
    -f Dockerfile-windows.local \
    -t "$IMAGE" \
    --push \
    .

echo "$IMAGE pushed."
