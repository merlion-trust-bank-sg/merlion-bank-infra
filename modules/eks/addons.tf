locals {
  # Every entry has the same fields so this is a proper map. role = key in local.roles (iam.tf) for
  # add-ons that call AWS through Pod Identity.
  addons = {
    # Needed before nodes can become Ready: pod networking and Pod Identity credentials
    vpc-cni                = { before_nodes = true, role = null, service_account = null }
    kube-proxy             = { before_nodes = true, role = null, service_account = null }
    eks-pod-identity-agent = { before_nodes = true, role = null, service_account = null }

    # These run as pods, so they need nodes first
    coredns            = { before_nodes = false, role = null, service_account = null }
    aws-ebs-csi-driver = { before_nodes = false, role = "ebs_csi", service_account = "ebs-csi-controller-sa" }
    # Pod CPU and memory use for HorizontalPodAutoscalers and kubectl top. No AWS access.
    metrics-server = { before_nodes = false, role = null, service_account = null }
  }

  # Volumes the EBS CSI driver creates (e.g. for Prometheus) aren't Terraform resources, so the
  # provider's default tags don't reach them. Tag them the same way, for cost tracking and the
  # training account's cleanup, which skips resources with our Project tag.
  addon_configuration = {
    aws-ebs-csi-driver = jsonencode({
      controller = { extraVolumeTags = data.aws_default_tags.current.tags }
    })
  }
}

data "aws_eks_addon_version" "latest" {
  for_each = local.addons

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "before_nodes" {
  for_each = { for k, v in local.addons : k => v if v.before_nodes }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.latest[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "after_nodes" {
  for_each = { for k, v in local.addons : k => v if !v.before_nodes }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.latest[each.key].version
  configuration_values        = lookup(local.addon_configuration, each.key, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  dynamic "pod_identity_association" {
    for_each = each.value.role != null ? [each.value] : []
    content {
      role_arn        = aws_iam_role.this[pod_identity_association.value.role].arn
      service_account = pod_identity_association.value.service_account
    }
  }

  depends_on = [aws_eks_node_group.default, aws_eks_addon.before_nodes]
}
