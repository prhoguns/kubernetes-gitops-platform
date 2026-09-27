#!/usr/bin/env bash
# Port-forward Argo CD (8080) and Grafana (3000) and print their admin passwords.
set -euo pipefail
secret() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }
echo "Argo CD  http://localhost:8080  admin / $(secret argocd argocd-initial-admin-secret password)"
echo "Grafana  http://localhost:3000  admin / $(secret monitoring grafana-admin admin-password)"
kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null &
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null &
trap 'kill $(jobs -p)' EXIT
wait
