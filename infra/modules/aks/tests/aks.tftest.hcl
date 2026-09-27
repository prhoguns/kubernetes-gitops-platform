# Tests against a mocked azurerm provider: no subscription or credentials needed.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000001" }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/demo-logs" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/demo-vnet/subnets/nodes" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/networkSecurityGroups/demo-nodes-nsg" }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ContainerService/managedClusters/demo" }
  }
}

variables {
  name                   = "demo"
  resource_group_name    = "rg"
  authorized_ip_ranges   = ["203.0.113.10/32"]
  admin_group_object_ids = ["11111111-1111-1111-1111-111111111111"]
}

run "identity_and_access" {
  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "The static local admin account must be disabled."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    error_message = "Kubernetes authorization must use Azure RBAC with Entra ID."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.workload_identity_enabled && azurerm_kubernetes_cluster.this.oidc_issuer_enabled
    error_message = "Workload identity must be on so pods do not need stored secrets."
  }
  assert {
    condition     = toset(azurerm_kubernetes_cluster.this.api_server_access_profile[0].authorized_ip_ranges) == toset(["203.0.113.10/32"])
    error_message = "A public API server must be limited to the authorized ranges."
  }
}

run "network_and_nodes" {
  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].network_policy == "cilium"
    error_message = "NetworkPolicy must be enforced."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].only_critical_addons_enabled
    error_message = "The system pool must be reserved for critical add-ons."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].host_encryption_enabled && azurerm_kubernetes_cluster_node_pool.workloads.host_encryption_enabled
    error_message = "Encryption at host must be on for every pool."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.default_node_pool[0].os_disk_type == "Ephemeral" && azurerm_kubernetes_cluster_node_pool.workloads.os_disk_type == "Ephemeral"
    error_message = "Nodes use ephemeral OS disks: faster, and nothing persists on a node between reimages."
  }
  assert {
    condition     = azurerm_subnet_network_security_group_association.nodes.network_security_group_id == azurerm_network_security_group.nodes.id
    error_message = "The node subnet must have an NSG."
  }
  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.workloads.zones) == 3
    error_message = "Workload nodes must spread across three availability zones."
  }
}

run "monitoring_and_patching" {
  assert {
    condition     = length(azurerm_kubernetes_cluster.this.microsoft_defender) == 1 && length(azurerm_kubernetes_cluster.this.oms_agent) == 1
    error_message = "Defender for Containers and Container Insights must be enabled."
  }
  assert {
    condition     = contains([for l in azurerm_monitor_diagnostic_setting.control_plane.enabled_log : l.category], "kube-audit-admin")
    error_message = "Kubernetes audit logs must be shipped to Log Analytics."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.automatic_upgrade_channel == "patch"
    error_message = "Patch versions must be applied automatically."
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.azure_policy_enabled
    error_message = "Azure Policy add-on must be enabled."
  }
}

run "private_cluster_needs_no_ip_ranges" {
  variables {
    private_cluster      = true
    authorized_ip_ranges = []
  }
  assert {
    condition     = azurerm_kubernetes_cluster.this.private_cluster_enabled && length(azurerm_kubernetes_cluster.this.api_server_access_profile) == 0
    error_message = "A private cluster has no public API allow-list."
  }
}

run "rejects_api_open_to_internet" {
  command = plan
  variables {
    authorized_ip_ranges = ["0.0.0.0/0"]
  }
  expect_failures = [var.authorized_ip_ranges]
}

run "rejects_public_api_without_ranges" {
  command = plan
  variables {
    authorized_ip_ranges = []
  }
  expect_failures = [var.authorized_ip_ranges]
}
