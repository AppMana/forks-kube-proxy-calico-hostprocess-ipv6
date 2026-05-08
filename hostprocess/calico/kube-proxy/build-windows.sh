#!/usr/bin/env bash
# Build the kube-proxy Calico HostProcess Windows image via the
# calico-windows-builder buildkit instance. Pre-fetches kube-proxy.exe and
# hns.psm1 (the Linux multi-stage curl path doesn't run on Windows-only
# buildkit) and then drives buildx against Dockerfile-windows.local.
#
# Usage:
#   ./build-windows.sh [<k8sVersion>] [<imageTag>]
# Defaults: k8sVersion=v1.34.6, imageTag=harbor.appmana.com/appmana-shared/kube-proxy:v1.34.6-calico-hostprocess
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

if ! docker buildx ls | grep -q '^calico-windows-builder'; then
    echo "calico-windows-builder buildx instance not found. Bootstrap with bin/fetch-buildkit-certs.sh." >&2
    exit 1
fi

echo "building $IMAGE..."
docker buildx build \
    --builder calico-windows-builder \
    --platform windows/amd64 \
    -f Dockerfile-windows.local \
    -t "$IMAGE" \
    --push \
    .

echo "$IMAGE pushed."
echo "Resolve digest with:"
echo "  curl -sk \"https://harbor.appmana.com/api/v2.0/projects/appmana-shared/repositories/kube-proxy/artifacts?with_tag=true\" | jq -r '.[] | select(.tags[]?.name == \"${K8S_VERSION}-calico-hostprocess\") | .digest'"
