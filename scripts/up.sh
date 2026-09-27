#!/usr/bin/env bash
# Create the local cluster and hand it to Argo CD. Everything after this comes from Git.
#   REVISION=<branch|sha> scripts/up.sh   deploy a specific revision (default: main)
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

REVISION=${REVISION:-main}
CLUSTER=gitops

if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind/cluster.yaml --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

terraform -chdir=infra/bootstrap init -input=false >/dev/null
terraform -chdir=infra/bootstrap apply -input=false -auto-approve -var "revision=$REVISION"

echo
echo "Argo CD is now syncing revision '$REVISION'. Watch it with:"
echo "  kubectl -n argocd get applications -w"
