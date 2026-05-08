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

# Use the Linux buildkit (lin-multi or buildkit-linux) — NOT the
# windows-only buildkit. Building host-process images on Windows hits a
# hcsshim::ImportLayer 0x3f1 bug on WS2022 / Win11 23H2-class builds; see
# moby/moby#44992 and microsoft/Windows-Containers#574. The Linux buildkit
# can compose Windows images for our Dockerfile because the Windows stage
# has no RUN steps.
BUILDER="${BUILDER:-lin-multi}"
UPSTREAM="docker.io/sigwindowstools/kube-proxy:${K8S_VERSION}-calico-hostprocess"

echo "building $IMAGE on $BUILDER (kube-proxy.exe pulled from $UPSTREAM)..."
docker buildx build \
    --builder "$BUILDER" \
    --platform windows/amd64 \
    --build-arg "UPSTREAM=$UPSTREAM" \
    -f Dockerfile-windows.local \
    -t "$IMAGE" \
    --push \
    .

echo "$IMAGE pushed."
echo "Resolve digest with:"
echo "  curl -sk \"https://harbor.appmana.com/api/v2.0/projects/appmana-shared/repositories/kube-proxy/artifacts?with_tag=true\" | jq -r '.[] | select(.tags[]?.name == \"${K8S_VERSION}-calico-hostprocess\") | .digest'"
