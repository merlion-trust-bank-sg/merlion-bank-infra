# Explicit Deny statements shared by the deploy roles and the workload permissions boundaries.
# An explicit Deny always wins, so these hold even if an Allow elsewhere is too broad.

# Bootstrap layer: state buckets and keys, CI roles, boundaries, ECR repos, the audit trail.
# Nothing the pipeline runs can weaken the audit trail or its own permissions.
#
# Split in two because the workload boundaries (boundary.tf) include it, and a managed policy can't
# exceed 6,144 characters:
#   protect_bootstrap_common   in the deploy roles' policy and in every boundary
#   protect_bootstrap_extra    in the deploy roles' policy only; each boundary already denies the same
#                              (DenyAllIam covers iam:*, DenyStateBuckets covers every state bucket)
data "aws_iam_policy_document" "protect_bootstrap" {
  source_policy_documents = [
    data.aws_iam_policy_document.protect_bootstrap_common.json,
    data.aws_iam_policy_document.protect_bootstrap_extra.json,
  ]
}

data "aws_iam_policy_document" "protect_bootstrap_extra" {
  statement {
    sid       = "DenyBootstrapState"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${var.state_buckets["bootstrap"]}", "arn:aws:s3:::${var.state_buckets["bootstrap"]}/*"]
  }

  statement {
    sid     = "DenyChangesToCiRolesAndBoundaries"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.a}:role/${local.p}-ci-*",
      "arn:aws:iam::${local.a}:policy/${local.p}-ci-*",
      "arn:aws:iam::${local.a}:policy/${local.p}-*-workload-boundary",
      "arn:aws:iam::${local.a}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  statement {
    sid       = "DenyRemovingBoundaries"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "protect_bootstrap_common" {
  statement {
    sid    = "DenyBucketConfigChanges"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketAcl",
      "s3:PutBucketOwnershipControls",
      "s3:PutReplicationConfiguration",
    ]
    resources = concat(
      [for b in values(var.state_buckets) : "arn:aws:s3:::${b}"],
      ["arn:aws:s3:::${local.audit_bucket}"],
    )
  }

  statement {
    sid       = "DenyBootstrapStateKey"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = [var.state_kms_key_arns["bootstrap"]]
  }

  statement {
    sid    = "DenyStateKeyAdmin"
    effect = "Deny"
    actions = [
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:DisableKeyRotation",
      "kms:CreateGrant",
      "kms:UpdateKeyDescription",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = concat(
      values(var.state_kms_key_arns),
      [for l in keys(var.state_kms_key_arns) : "arn:aws:kms:${local.r}:${local.a}:alias/${local.p}-${l}-state"],
    )
  }

  # The audit key: encrypt new deploy records and EKS audit log deliveries (kms:GenerateDataKey),
  # nothing else. No decrypt (so the audit logs can't be read back), and no changes to the key; the
  # key policy also denies those. Also binds the Firehose role, which carries the env's boundary.
  statement {
    sid         = "AuditKeyEncryptOnly"
    effect      = "Deny"
    not_actions = ["kms:GenerateDataKey", "kms:DescribeKey"]
    resources   = [var.audit_kms_key_arn]
  }

  # EKS control-plane logs (incl. the Kubernetes audit log, HC-3). The pipeline creates the log group
  # but can't delete it, its streams or the export to the audit bucket. Tearing an environment down
  # leaves the log group behind (skip_destroy in modules/eks). PutRetentionPolicy stays allowed:
  # Terraform sets retention right after creating the group; modules/eks validates it's at least a
  # year, and the copy in the Object Lock bucket doesn't depend on it.
  statement {
    sid    = "DenyEksLogTampering"
    effect = "Deny"
    actions = [
      "logs:DeleteLogGroup",
      "logs:DeleteLogStream",
      "logs:DeleteRetentionPolicy",
      "logs:DeleteSubscriptionFilter",
      "logs:DisassociateKmsKey",
    ]
    resources = local.eks_log_group_arns
  }

  # Write deploy records, never read the audit trail back or remove anything from it
  statement {
    sid    = "DenyAuditTampering"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
      "s3:BypassGovernanceRetention",
    ]
    resources = ["arn:aws:s3:::${local.audit_bucket}/*"]
  }

  statement {
    sid    = "DenyTrailChanges"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:PutInsightSelectors",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyEcrRepoChanges"
    effect = "Deny"
    actions = [
      "ecr:DeleteRepository",
      "ecr:DeleteRepositoryPolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:PutLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageTagMutability",
      "ecr:PutImageScanningConfiguration",
      "ecr:BatchDeleteImage",
    ]
    resources = [local.ecr_repo_arn]
  }

  # Data residency: nothing outside the one approved region
  statement {
    sid         = "DenyOutsideApprovedRegion"
    effect      = "Deny"
    not_actions = local.global_actions
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

# Environment fence: each env role (and everything it creates) stays inside its own environment
data "aws_iam_policy_document" "env_fence" {
  for_each = var.environments

  # Anything tagged with an Environment other than this one (the other env, or "shared" bootstrap).
  # Untagged resources aren't matched here; the name-based statement and the boundary cover them.
  statement {
    sid     = "DenyOtherEnvironmentByTag"
    effect  = "Deny"
    actions = ["*"]
    # Shared by both environments and tagged "shared" by bootstrap, so exempted here:
    # - the ECR repositories (same image digest in staging and prod): without this, nodes couldn't
    #   pull images. Pushes and repository changes stay denied by protect_bootstrap and the boundary.
    # - the audit key: deploy records are encrypted with it, so writing one needs kms:GenerateDataKey.
    #   The key policy denies our roles any change to the key, and nothing grants them decrypt.
    not_resources = [local.ecr_repo_arn, var.audit_kms_key_arn]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Environment"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [each.key]
    }
  }

  # ...and can't create or re-tag something into another environment
  statement {
    sid       = "DenyTaggingIntoOtherEnvironment"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/Environment"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Environment"
      values   = [each.key]
    }
  }

  statement {
    sid       = "DenyOtherEnvironmentByName"
    effect    = "Deny"
    actions   = ["*"]
    resources = flatten([for e in keys(var.environments) : local.env_named_arns[e] if e != each.key])
  }

  statement {
    sid       = "DenyOtherEnvironmentStateKey"
    effect    = "Deny"
    actions   = ["kms:*"]
    resources = [for e in keys(var.environments) : var.state_kms_key_arns[e] if e != each.key]
  }
}
