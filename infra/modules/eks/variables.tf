variable "name" {
  description = "Cluster name; also prefixes the VPC, IAM roles and keys."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, 2-31 characters."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. null lets EKS choose its current default; pin it in production."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR for the cluster VPC. Split into three private and three public /20s."
  type        = string
  default     = "10.40.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT gateway for all AZs (cheaper) instead of one per AZ (survives an AZ outage)."
  type        = bool
  default     = true
}

variable "public_endpoint" {
  description = "Expose the Kubernetes API publicly (restricted to public_access_cidrs). Private access is always on."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint, e.g. an office or VPN egress IP."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not open the Kubernetes API to the whole internet; list specific CIDRs."
  }

  # EKS treats an empty list as 0.0.0.0/0, so a public endpoint must name its CIDRs explicitly.
  validation {
    condition     = !var.public_endpoint || length(var.public_access_cidrs) > 0
    error_message = "public_endpoint is true, so public_access_cidrs must list at least one CIDR."
  }
}

variable "admin_principal_arns" {
  description = "IAM roles/users granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "log_retention_days" {
  description = "Retention for control-plane and VPC flow logs. A year covers most audit requirements."
  type        = number
  default     = 365
}

variable "availability_zones" {
  description = <<-EOT
    Exactly three AZ names for the subnets. Leave empty to use the region's first three, but pin
    them in production: if AWS adds a zone that sorts earlier, the automatic choice would shift and
    Terraform would try to replace subnets.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 3
    error_message = "availability_zones must be empty or list exactly three zones."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
