# Kubernetes GitOps Platform

_Work in progress: the platform (Argo CD, Kyverno, Prometheus/Grafana) and full write-up land in the next commits._

GitOps repo for a local Kubernetes platform. `workloads/demo-api` is deployed by digest; the digest is
promoted automatically by [devsecops-supply-chain](https://github.com/prhoguns/devsecops-supply-chain)
after the image passes its security gates and is signed.
