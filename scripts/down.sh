#!/usr/bin/env bash
# Delete the local cluster and the Terraform state that pointed at it.
set -euo pipefail
cd "$(dirname "$0")/.."
kind delete cluster --name gitops
rm -f infra/bootstrap/terraform.tfstate infra/bootstrap/terraform.tfstate.backup
