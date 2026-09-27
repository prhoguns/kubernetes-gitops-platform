# Bootstrap: the only thing Terraform installs into the cluster is Argo CD and one root
# Application. Everything else (Kyverno, policies, monitoring, workloads) is declared in Git and
# reconciled by Argo CD, so the cluster can be rebuilt from this repo alone.

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  values           = [file("${path.module}/values/argocd.yaml")]
  wait             = true
  timeout          = 600
}

# The root "app of apps". It renders argocd/apps, a small Helm chart that emits the AppProjects
# and one Application per platform component, all pinned to the same revision.
resource "helm_release" "root_app" {
  name       = "root-app"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.5"

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.repo_url
          targetRevision = var.revision
          path           = "argocd/apps"
          helm = {
            valuesObject = {
              repoURL  = var.repo_url
              revision = var.revision
            }
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["RespectIgnoreDifferences=true"]
        }
        # Argo CD adds pre-delete finalizers to child Applications whose charts have pre-delete
        # hooks (Kyverno does). They are controller-managed, so the root app must not fight them.
        ignoreDifferences = [{
          group             = "argoproj.io"
          kind              = "Application"
          jqPathExpressions = [".metadata.finalizers[] | select(startswith(\"pre-delete-finalizer.argocd.argoproj.io\"))"]
        }]
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
