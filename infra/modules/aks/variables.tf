variable "name" {
  description = "Cluster name; also prefixes the network and Log Analytics workspace."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, 2-31 characters."
  }
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region, e.g. canadacentral."
  type        = string
  default     = "canadacentral"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null lets AKS choose its current default; pin it in production."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "Free for dev/test; Standard adds the uptime SLA for production."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "vnet_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "private_cluster" {
  description = "API server reachable only from inside the VNet (or peered networks)."
  type        = bool
  default     = false
}

variable "authorized_ip_ranges" {
  description = "CIDRs allowed to reach a public API server. Required unless private_cluster is true."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.authorized_ip_ranges, "0.0.0.0/0")
    error_message = "Do not open the Kubernetes API to the whole internet; list specific CIDRs."
  }

  validation {
    condition     = var.private_cluster || length(var.authorized_ip_ranges) > 0
    error_message = "A public API server must be restricted with authorized_ip_ranges."
  }
}

variable "admin_group_object_ids" {
  description = "Entra ID group object IDs that get cluster-admin through Azure RBAC."
  type        = list(string)
  default     = []
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D2ds_v5" # "d" sizes have a local disk, needed for ephemeral OS disks
}

variable "workload_vm_size" {
  type    = string
  default = "Standard_D4ds_v5"
}

variable "workload_min_count" {
  type    = number
  default = 2
}

variable "workload_max_count" {
  type    = number
  default = 6
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
