# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security → Report a vulnerability** on this repository
([private vulnerability reporting](https://github.com/prhoguns/kubernetes-gitops-platform/security/advisories/new)).
Do not open a public issue for a suspected vulnerability.

Include what you found, how to reproduce it, and the commit or image digest affected. I aim to
acknowledge reports within 3 business days and to share a fix or mitigation plan within 14 days.

## Scope

- Everything this repository deploys: the Terraform bootstrap, the Argo CD applications, the
  Kyverno policies, the monitoring configuration and the demo-api manifests.
- The EKS and AKS Terraform modules in `infra/modules/`.
- A way to get an image admitted that the policies should reject is in scope and especially
  welcome.

## Supported versions

Only `main` is supported.
