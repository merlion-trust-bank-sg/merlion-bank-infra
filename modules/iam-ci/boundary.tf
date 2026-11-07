# Permissions boundary for every role the env pipeline creates (EKS cluster, nodes, Pod Identity
# roles). The role's own policies grant access; the boundary caps the maximum it can ever have.
data "aws_iam_policy_document" "workload_boundary_base" {
  #checkov:skip=CKV_AWS_1:Permissions boundary, not a grant: Allow * is neutral, the Deny statements set the ceiling
  #checkov:skip=CKV_AWS_49:Permissions boundary: Allow * only caps; the role's own narrow policies grant access
  #checkov:skip=CKV_AWS_107:Permissions boundary: grants nothing; credentials access depends on the role's own policies
  #checkov:skip=CKV_AWS_108:Permissions boundary: grants nothing; state buckets, audit and other env are denied
  #checkov:skip=CKV_AWS_109:Permissions boundary: all IAM actions are denied by DenyAllIam
  #checkov:skip=CKV_AWS_110:Permissions boundary: all IAM actions are denied by DenyAllIam, so no escalation
  #checkov:skip=CKV_AWS_111:Permissions boundary: grants nothing; writes depend on the role's own policies
  #checkov:skip=CKV_AWS_356:Permissions boundary: Resource * is needed to cap every service; Deny statements narrow it
  statement {
    sid       = "AllowWithinGuardrails"
    actions   = ["*"]
    resources = ["*"]
  }

  # Workloads (nodes, pods) never need IAM
  statement {
    sid       = "DenyAllIam"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["*"]
  }

  statement {
    sid       = "DenyStateBuckets"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = flatten([for b in values(var.state_buckets) : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }

  statement {
    sid    = "DenyImagePush"
    effect = "Deny"
    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [local.ecr_repo_arn]
  }
}

data "aws_iam_policy_document" "workload_boundary" {
  for_each = var.environments
  source_policy_documents = [
    data.aws_iam_policy_document.workload_boundary_base.json,
    data.aws_iam_policy_document.protect_bootstrap.json,
    data.aws_iam_policy_document.env_fence[each.key].json,
  ]
}

resource "aws_iam_policy" "workload_boundary" {
  for_each = var.environments

  name        = "${local.p}-${each.key}-workload-boundary"
  description = "Permissions boundary for every role created by the ${each.key} pipeline"
  policy      = data.aws_iam_policy_document.workload_boundary[each.key].json
}
