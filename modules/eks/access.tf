# Cluster access is granted with EKS access entries (no aws-auth ConfigMap)
locals {
  # Admin wins if a principal is in both lists, so it never gets two entries
  access = merge(
    { for arn in var.viewer_principal_arns : arn => "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy" },
    { for arn in var.admin_principal_arns : arn => "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" },
  )
}

resource "aws_eks_access_entry" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = each.value

  access_scope {
    type = "cluster"
  }
}
