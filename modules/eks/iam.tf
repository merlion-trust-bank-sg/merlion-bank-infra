# Every role carries the env's permissions boundary and is named <name>-*: the env CI role may only
# create roles like that (IamWithBoundary in the bootstrap deploy policy).
locals {
  roles = {
    # Control plane
    cluster = {
      name     = "${var.name}-eks-cluster"
      service  = "eks.amazonaws.com"
      actions  = ["sts:AssumeRole", "sts:TagSession"]
      policies = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
    }
    # Worker nodes. The CNI policy stays here instead of on a Pod Identity role: vpc-cni runs on the
    # host network and this is the AWS default. Everything else that needs AWS access uses Pod Identity.
    node = {
      name    = "${var.name}-eks-node"
      service = "ec2.amazonaws.com"
      actions = ["sts:AssumeRole"]
      policies = [
        "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      ]
    }
    # Pod Identity role for the EBS CSI driver (Prometheus volumes)
    ebs_csi = {
      name     = "${var.name}-ebs-csi"
      service  = "pods.eks.amazonaws.com"
      actions  = ["sts:AssumeRole", "sts:TagSession"]
      policies = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
  }

  role_policy_attachments = merge([for r, role in local.roles : {
    for p in role.policies : "${r}/${basename(p)}" => { role = r, policy_arn = p }
  }]...)
}

data "aws_iam_policy_document" "trust" {
  for_each = local.roles

  statement {
    actions = each.value.actions
    principals {
      type        = "Service"
      identifiers = [each.value.service]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name                 = each.value.name
  assume_role_policy   = data.aws_iam_policy_document.trust[each.key].json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.role_policy_attachments

  role       = aws_iam_role.this[each.value.role].name
  policy_arn = each.value.policy_arn
}

# The cluster encrypts Kubernetes secrets with our key. The key policy delegates to IAM, so the
# cluster role needs this on that one key.
data "aws_iam_policy_document" "cluster_encryption" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [module.secrets_key.arn]
  }
}

resource "aws_iam_role_policy" "cluster_encryption" {
  name   = "${var.name}-eks-cluster-encryption"
  role   = aws_iam_role.this["cluster"].id
  policy = data.aws_iam_policy_document.cluster_encryption.json
}
