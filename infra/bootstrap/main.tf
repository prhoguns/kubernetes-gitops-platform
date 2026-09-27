# Bootstrap: the only thing Terraform installs into the cluster is Argo CD and one root
# Application. Everything else (Kyverno, policies, monitoring, workloads) is declared in Git and
# reconciled by Argo CD, so the cluster can be rebuilt from this repo alone.

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

# Secrets are created here, once, and never committed to Git. The Grafana chart only references
# this secret by name (platform/monitoring/values.yaml). Letting the chart generate a password
# does not work under Argo CD: every render produces a new random value, so the stored secret
# drifts away from the password Grafana actually initialised with.
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }

  lifecycle {
    # Argo CD adds its own tracking labels and annotations after it takes the namespace over.
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
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
