#!/usr/bin/env bash
# Pull the Argo CD chart's images on the host, retrying with backoff, and load them into the kind
# nodes. CI runners share IP addresses, and public registries (ecr-public in particular) answer
# anonymous pulls from them with 429 Too Many Requests often enough to fail a bootstrap. Loading
# the images up front means the cluster never has to pull them itself.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=gitops
chart_version=$(awk '/variable "argocd_chart_version"/{f=1} f && /default/{gsub(/[" ]/,"",$3); print $3; exit}' infra/bootstrap/variables.tf)

images=$(helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$chart_version" \
  -f infra/bootstrap/values/argocd.yaml | grep -oE 'image: *"?[^" ]+' | awk '{print $2}' | tr -d '"' | sort -u)

for image in $images; do
  for attempt in 1 2 3 4 5; do
    if docker pull -q "$image" >/dev/null; then break; fi
    [ "$attempt" -eq 5 ] && { echo "could not pull $image" >&2; exit 1; }
    echo "pull of $image failed (attempt $attempt), retrying in $((attempt * 20))s" >&2
    sleep $((attempt * 20))
  done
  # Import into each node's containerd for this platform only. (`kind load docker-image` imports
  # --all-platforms, which fails when Docker holds a multi-platform index but only one platform's
  # layers, the default with Docker's containerd image store.)
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker save "$image" | docker exec -i "$node" \
      ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs --platform "linux/$(dpkg --print-architecture 2>/dev/null || echo amd64)" - >/dev/null
  done
  echo "loaded $image"
done
