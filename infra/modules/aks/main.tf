data "azurerm_client_config" "current" {}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name}-logs"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 4, 0)]
}

# Subnet-level NSG with only Azure's default rules (VNet and load balancer traffic in, nothing
# from the internet). AKS manages its own rules on the node NICs for Services it exposes.
resource "azurerm_network_security_group" "nodes" {
  name                = "${var.name}-nodes-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

resource "azurerm_kubernetes_cluster" "this" {
  # checkov:skip=CKV_AZURE_6: authorized_ip_ranges is set in a dynamic block (required by variable validation when the API is public)
  # checkov:skip=CKV_AZURE_115: private cluster is a variable; the dev default is a public API limited to authorized ranges
  # checkov:skip=CKV_AZURE_170: sku_tier is a variable; Free for dev, Standard for production
  # checkov:skip=CKV_AZURE_117: disks are encrypted at host with platform-managed keys; customer-managed keys are out of scope here
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  # Security patches land automatically; node images are refreshed weekly.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  private_cluster_enabled = var.private_cluster

  dynamic "api_server_access_profile" {
    for_each = var.private_cluster ? [] : [1]
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  # System pool runs only cluster-critical add-ons; workloads go to the user pool below.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = azurerm_subnet.nodes.id
    zones                        = ["1", "2", "3"]
    auto_scaling_enabled         = true
    min_count                    = 2
    max_count                    = 3
    only_critical_addons_enabled = true
    host_encryption_enabled      = true
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = 64
    max_pods                     = 50
    os_sku                       = "AzureLinux"
    upgrade_settings {
      max_surge = "33%"
    }
    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  # Node pools below scale with the cluster autoscaler ("Manual"), not AKS node auto-provisioning.
  node_provisioning_profile {
    mode = "Manual"
  }

  # Entra ID sign-in with Azure RBAC for Kubernetes; the static local admin account is disabled,
  # so every API call is tied to a real identity and shows up in the audit log.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
  }

  # Workload identity: pods get Entra tokens through federated credentials, no stored secrets.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  azure_policy_enabled = true

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  tags = var.tags

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "workloads" {
  name                    = "workloads"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.this.id
  vm_size                 = var.workload_vm_size
  vnet_subnet_id          = azurerm_subnet.nodes.id
  zones                   = ["1", "2", "3"]
  auto_scaling_enabled    = true
  min_count               = var.workload_min_count
  max_count               = var.workload_max_count
  host_encryption_enabled = true
  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = 128
  max_pods                = 50
  os_sku                  = "AzureLinux"
  mode                    = "User"
  upgrade_settings {
    max_surge = "33%"
  }
  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# Control-plane logs (including kube-audit) to Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "control_plane" {
  name                       = "control-plane"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  dynamic "enabled_log" {
    for_each = ["kube-apiserver", "kube-audit-admin", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "guard"]
    content {
      category = enabled_log.value
    }
  }
}
