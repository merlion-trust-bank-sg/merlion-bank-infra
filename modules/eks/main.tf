# Kubernetes secrets are encrypted with our own key (envelope encryption on top of EKS's default).
# The cluster role gets access through its own IAM policy (iam.tf).
module "secrets_key" {
  source = "../kms"

  name        = "${var.name}-eks-secrets"
  description = "${var.name} EKS secrets encryption"
}

# Created before the cluster so EKS writes into it with our retention and key, instead of creating
# its own group that never expires and isn't encrypted with our key
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.cluster_log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  # It holds the Kubernetes audit log (HC-3): a teardown leaves it in place instead of deleting it
  # (the pipeline is also denied DeleteLogGroup). A rebuild reuses it; import it first if it's left over.
  skip_destroy = true
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_39:Public endpoint is needed: GitHub-hosted runners (Helm releases) have no fixed IPs. Every call still needs IAM auth and an access entry
  #checkov:skip=CKV_AWS_38:Same reason; the allowed CIDRs are set per env (public_access_cidrs)
  #checkov:skip=CKV_AWS_339:Its hard-coded version list (unchanged since Mar 2026) stops at 1.35; 1.37 is in EKS standard support
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.this["cluster"].arn

  # All control-plane logs. audit = who changed what in Kubernetes; authenticator = which IAM identity
  # logged in; api, controllerManager, scheduler help diagnose cluster problems.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = module.secrets_key.arn
    }
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.this,
    aws_iam_role_policy.cluster_encryption,
    aws_cloudwatch_log_group.cluster,
  ]
}

# Node launch template. Only settings EKS lets us own: metadata options and the root disk (disk_size
# can't also be set on the node group). No AMI ID, so EKS still picks the AL2023 EKS AMI and adds the
# bootstrap user data itself.
resource "aws_launch_template" "node" {
  name_prefix            = "${var.name}-node-"
  update_default_version = true

  # IMDSv2 only, hop limit 1: the node itself can reach instance metadata, normal pods can't, so a
  # compromised pod can't take the node role's credentials. Pods that need AWS use Pod Identity
  # (credentials from the node-local agent at 169.254.170.23, not from IMDS).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # default_tags on the provider tag the launch template itself, not the instances the node group's
  # Auto Scaling group starts. Tag those too, for cost tracking and the env/project tag guardrails.
  dynamic "tag_specifications" {
    for_each = ["instance", "volume", "network-interface"]
    content {
      resource_type = tag_specifications.value
      tags          = data.aws_default_tags.current.tags
    }
  }
}

data "aws_default_tags" "current" {}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.this["node"].arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.this]

  lifecycle {
    # Leave room for a cluster autoscaler to change the count later without Terraform reverting it
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# EKS creates the node group's Auto Scaling group itself and doesn't copy our tags onto it, so tag it
# here. Without the Project tag the training account's nightly cleanup deletes the group, which
# terminates every node. Not propagated: the launch template already tags the instances.
resource "aws_autoscaling_group_tag" "node" {
  for_each = data.aws_default_tags.current.tags

  autoscaling_group_name = aws_eks_node_group.default.resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = false
  }
}
