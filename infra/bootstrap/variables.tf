variable "kubeconfig_path" {
  description = "Kubeconfig used to reach the cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context of the target cluster. kind names it kind-<cluster name>."
  type        = string
  default     = "kind-gitops"
}

variable "repo_url" {
  description = "Git repository Argo CD syncs from."
  type        = string
  default     = "https://github.com/prhoguns/kubernetes-gitops-platform.git"
}

variable "revision" {
  description = "Branch, tag or commit to deploy. CI sets this to the commit under test."
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version."
  type        = string
  default     = "10.9.2"
}
