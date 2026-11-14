locals {
  p = var.prefix
  a = var.account_id
  r = var.region

  role_names = merge(
    { for e in keys(var.environments) : e => "${local.p}-ci-${e}" },
    {
      build     = "${local.p}-ci-build"
      plan      = "${local.p}-ci-plan"
      prod_plan = "${local.p}-ci-prod-plan"
    },
  )

  # Each env's permissions boundary (created below). Every role the env pipeline creates must carry it.
  boundary_arns = { for e in keys(var.environments) :
    e => "arn:aws:iam::${local.a}:policy/${local.p}-${e}-workload-boundary"
  }

  # Resources owned by one environment, identified by name. Allowed for that env, denied to the other.
  env_named_arns = { for e in keys(var.environments) : e => [
    "arn:aws:s3:::${local.p}-${e}-*",
    "arn:aws:s3:::${local.p}-${e}-*/*",
    # EKS: cluster/<name>, nodegroup/<name>/..., addon/..., access-entry/..., podidentityassociation/...
    "arn:aws:eks:${local.r}:${local.a}:*/${local.p}-${e}*",
    # RDS: db:, subgrp:, pg:, og:, snapshot:, snapshot:rds: (the * also matches the colons)
    "arn:aws:rds:${local.r}:${local.a}:*:${local.p}-${e}*",
    "arn:aws:iam::${local.a}:role/${local.p}-${e}-*",
    "arn:aws:iam::${local.a}:policy/${local.p}-${e}-*",
    "arn:aws:secretsmanager:${local.r}:${local.a}:secret:${local.p}/${e}/*",
    "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/eks/${local.p}-${e}/*",
    "arn:aws:logs:${local.r}:${local.a}:log-group:/${local.p}/${e}/*",
    "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/vpc/${local.p}-${e}*",
    "arn:aws:sns:${local.r}:${local.a}:${local.p}-${e}-*",
    "arn:aws:firehose:${local.r}:${local.a}:deliverystream/${local.p}-${e}-*",
    "arn:aws:cloudwatch:${local.r}:${local.a}:alarm:${local.p}-${e}-*",
  ] }

  # Every env's EKS control-plane log group (and its streams)
  eks_log_group_arns = [
    "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/eks/${local.p}-*",
    "arn:aws:logs:${local.r}:${local.a}:log-group:/aws/eks/${local.p}-*:*",
  ]

  # Created by other bootstrap PRs; protected by name so the rules hold as soon as they exist
  audit_bucket = "${local.p}-audit-${local.a}"
  ecr_repo_arn = "arn:aws:ecr:${local.r}:${local.a}:repository/merlion/*"

  # Services with no region, left out of the region lock
  global_actions = [
    "iam:*", "sts:*", "organizations:*", "account:*", "support:*", "budgets:*",
    "ce:*", "cur:*", "route53:*", "route53domains:*", "cloudfront:*", "waf:*",
    "health:*", "trustedadvisor:*", "s3:GetBucketLocation", "s3:ListAllMyBuckets",
  ]
}
