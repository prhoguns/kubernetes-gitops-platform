# Plan-and-apply tests against a mocked AWS provider: no account or credentials needed.
# They pin the security properties of the module so a refactor cannot silently drop them.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["ca-central-1a", "ca-central-1b", "ca-central-1d"] }
  }
  mock_data "aws_region" {
    defaults = { region = "ca-central-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:ca-central-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ca-central-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:ca-central-1:123456789012:cluster/demo"
      certificate_authority = [{ data = "bW9jay1jYQ==" }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
}

variables {
  name                 = "demo"
  public_access_cidrs  = ["203.0.113.10/32"]
  admin_principal_arns = ["arn:aws:iam::123456789012:role/platform-admin"]
}

run "control_plane_is_locked_down" {
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "Private API endpoint must always be on."
  }
  assert {
    condition     = toset(aws_eks_cluster.this.vpc_config[0].public_access_cidrs) == toset(["203.0.113.10/32"])
    error_message = "Public API endpoint must be limited to the given CIDRs."
  }
  assert {
    condition     = contains(aws_eks_cluster.this.encryption_config[0].resources, "secrets")
    error_message = "Kubernetes Secrets must be envelope-encrypted with KMS."
  }
  assert {
    condition     = length(aws_eks_cluster.this.enabled_cluster_log_types) == 5
    error_message = "All five control-plane log types (including audit) must be enabled."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "Use EKS access entries, not the aws-auth ConfigMap."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "The identity running Terraform must not get implicit cluster-admin."
  }
  assert {
    condition     = length(aws_eks_access_policy_association.admin) == 1
    error_message = "Admins are granted access explicitly through access entries."
  }
  assert {
    condition     = aws_kms_key.this.enable_key_rotation
    error_message = "KMS key rotation must be enabled."
  }
}

run "nodes_are_private_and_hardened" {
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required"
    error_message = "Nodes must require IMDSv2."
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit must be 1 so pods cannot read node credentials."
  }
  assert {
    condition     = aws_launch_template.node.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "Node volumes must be encrypted."
  }
  assert {
    condition     = toset(aws_eks_node_group.default.subnet_ids) == toset(aws_subnet.private[*].id)
    error_message = "Nodes must run only in private subnets."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "No subnet may hand out public IPs automatically."
  }
  assert {
    condition     = jsondecode(aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy == "true"
    error_message = "The VPC CNI must enforce NetworkPolicy."
  }
  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "VPC flow logs must capture all traffic."
  }
}

run "single_nat_by_default" {
  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "Default is one shared NAT gateway."
  }
}

run "one_nat_per_az_when_requested" {
  variables {
    single_nat_gateway = false
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "HA mode needs a NAT gateway per AZ."
  }
  assert {
    condition     = length(toset([for rt in aws_route_table.private : one(rt.route).nat_gateway_id])) == 3
    error_message = "Each private subnet must route through its own AZ's NAT gateway."
  }
}

run "private_only_cluster" {
  variables {
    public_endpoint     = false
    public_access_cidrs = []
  }
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false
    error_message = "public_endpoint = false must turn the public endpoint off."
  }
}

run "rejects_api_open_to_internet" {
  command = plan
  variables {
    public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.public_access_cidrs]
}

run "rejects_public_endpoint_without_cidrs" {
  command = plan
  variables {
    public_access_cidrs = []
  }
  expect_failures = [var.public_access_cidrs]
}
