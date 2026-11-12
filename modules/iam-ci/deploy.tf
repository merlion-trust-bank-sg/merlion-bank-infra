# What each env role may change. The guardrails (protect_bootstrap, env_fence) narrow it further.
resource "aws_iam_role_policy_attachment" "env_read_only" {
  for_each   = var.environments
  role       = aws_iam_role.ci[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "deploy" {
  #checkov:skip=CKV_AWS_356:EC2, ELB, Auto Scaling, KMS and ACM resources get random IDs, so they can't be scoped by name; the env fence and Team denies limit them
  #checkov:skip=CKV_AWS_109:IAM changes only on own-env roles carrying the env's permissions boundary (IamWithBoundary); broad policies can't be attached
  #checkov:skip=CKV_AWS_111:Writes are limited to own-env names, or to unscoped services narrowed by the env fence and Team denies
  #checkov:skip=CKV_AWS_107:No secret reads: only RDS-managed secret create/tag; GetSecretValue is never granted
  for_each = var.environments

  # Services whose resources can be scoped by name to this env
  statement {
    sid = "OwnNamedResources"
    actions = [
      "eks:*",
      "rds:*",
      "s3:*",
      "secretsmanager:*",
      "logs:*",
      "sns:*",
      "firehose:*",
      "cloudwatch:*",
    ]
    resources = local.env_named_arns[each.key]
  }

  # Services that can't be scoped by name (VPC, load balancers, keys, certificates). kms:* includes
  # this env's own state key; the fence denies the other env's key and protect_bootstrap the rest.
  statement {
    sid = "NetworkingAndKeys"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "kms:*",
      "acm:*",
    ]
    resources = ["*"]
  }

  # manage_master_user_password: RDS creates the rds!... secret on the caller's behalf, so the caller
  # needs CreateSecret + TagResource. RDS rotates and deletes it itself; the password is never readable.
  statement {
    sid       = "RdsManagedSecretsCreate"
    actions   = ["secretsmanager:CreateSecret", "secretsmanager:TagResource"]
    resources = ["arn:aws:secretsmanager:${local.r}:${local.a}:secret:rds!*"]
  }

  # Roles this pipeline creates (EKS, nodes, Pod Identity) must carry the env's permissions boundary,
  # so they can never have more than it allows. This blocks privilege escalation through new roles.
  statement {
    sid = "IamWithBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.a}:role/${local.p}-${each.key}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arns[each.key]]
    }
  }

  # No iam:UpdateAssumeRolePolicy: trust policies are set at CreateRole and never changed by the pipeline
  statement {
    sid = "IamManageOwnRolesAndPolicies"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${local.a}:role/${local.p}-${each.key}-*",
      "arn:aws:iam::${local.a}:policy/${local.p}-${each.key}-*",
    ]
  }

  statement {
    sid    = "DenyAttachingBroadPolicies"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/PowerUserAccess",
        "arn:aws:iam::aws:policy/IAMFullAccess",
        "arn:aws:iam::aws:policy/*FullAccess",
      ]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "autoscaling.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  # DNS validation records for the env's ACM certificate, in the course's shared zone. Only names under
  # the env's own hostname: other groups have records in this zone.
  statement {
    sid       = "OwnDnsRecordsOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["*.${var.dns_names[each.key]}"]
    }
  }

  # Deploy records for the audit trail: write-only, own env's prefix
  statement {
    sid       = "WriteDeployRecords"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.audit_bucket}/deploys/${each.key}/*"]
  }

  # ec2:*, elasticloadbalancing:* and autoscaling:* above are on "*", so protect other groups'
  # resources in this shared account. Untagged resources count as "not ours" for destroy actions.
  statement {
    sid    = "DenyDestroyingOtherTeams"
    effect = "Deny"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:DeleteVpc",
      "ec2:DeleteSubnet",
      "ec2:DeleteNatGateway",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteVolume",
      "ec2:ReleaseAddress",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
      "autoscaling:DeleteAutoScalingGroup",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Team"
      values   = [var.team]
    }
  }

  # Changes only on resources that clearly belong to another team. Untagged ones are allowed here,
  # because AWS creates a VPC's default security group, NACL and route table untagged and the VPC
  # module then tags them and removes their default rules.
  statement {
    sid    = "DenyChangingOtherTeams"
    effect = "Deny"
    actions = [
      "ec2:Delete*",
      "ec2:Modify*",
      "ec2:Authorize*",
      "ec2:Revoke*",
      "ec2:Associate*",
      "ec2:Disassociate*",
      "ec2:Attach*",
      "ec2:Detach*",
      "ec2:Replace*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "elasticloadbalancing:Modify*",
      "elasticloadbalancing:Register*",
      "elasticloadbalancing:Deregister*",
      "elasticloadbalancing:Add*",
      "elasticloadbalancing:Remove*",
      "elasticloadbalancing:Set*",
      "autoscaling:Update*",
      "autoscaling:Set*",
      "autoscaling:Terminate*",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Team"
      values   = [var.team]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Team"
      values   = ["false"]
    }
  }

  # Application logs can hold customer data; the pipeline never reads them
  statement {
    sid       = "DenyAppLogs"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["arn:aws:s3:::${local.p}-*-loki/*"]
  }
}

# Three managed policies per env role, each kept under IAM's 6,144-character limit
resource "aws_iam_policy" "deploy" {
  for_each = var.environments

  name        = "${local.p}-ci-${each.key}-deploy"
  description = "What the ${each.key} pipeline may change"
  policy      = data.aws_iam_policy_document.deploy[each.key].json
}

resource "aws_iam_policy" "protect_bootstrap" {
  name        = "${local.p}-ci-protect-bootstrap"
  description = "Deny changes to state, CI roles, boundaries, ECR and the audit trail; region lock"
  policy      = data.aws_iam_policy_document.protect_bootstrap.json
}

resource "aws_iam_policy" "env_fence" {
  for_each = var.environments

  name        = "${local.p}-ci-${each.key}-fence"
  description = "Deny everything outside the ${each.key} environment"
  policy      = data.aws_iam_policy_document.env_fence[each.key].json
}

locals {
  env_role_policies = merge([for e in keys(var.environments) : {
    "${e}-deploy"  = { env = e, arn = aws_iam_policy.deploy[e].arn }
    "${e}-protect" = { env = e, arn = aws_iam_policy.protect_bootstrap.arn }
    "${e}-fence"   = { env = e, arn = aws_iam_policy.env_fence[e].arn }
  }]...)
}

resource "aws_iam_role_policy_attachment" "env_policies" {
  for_each   = local.env_role_policies
  role       = aws_iam_role.ci[each.value.env].name
  policy_arn = each.value.arn
}
