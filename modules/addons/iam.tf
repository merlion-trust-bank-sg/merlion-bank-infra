# AWS side of the cluster add-ons: Pod Identity roles and their links to the add-ons' service accounts.
# The add-ons themselves are installed by Argo CD from deploy/platform/. Roles are named <name>-* with
# the env's permissions boundary, so the env CI role may create them.

# --- AWS Load Balancer Controller ---------------------------------------------------------------
# The controller's own published policy (policies/aws-load-balancer-controller.json, v3.6.2). Update it
# together with the chart version.
resource "aws_iam_role" "lb_controller" {
  name                 = "${var.name}-lb-controller"
  assume_role_policy   = var.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "lb_controller" {
  name   = "${var.name}-lb-controller"
  role   = aws_iam_role.lb_controller.id
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}

# --- External Secrets Operator ------------------------------------------------------------------
# Read only the listed secrets and decrypt only with their key: no listing, no writing
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid       = "ReadListedSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.readable_secret_arns
  }

  statement {
    sid       = "DecryptThem"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name                 = "${var.name}-external-secrets"
  assume_role_policy   = var.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${var.name}-external-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

# --- ExternalDNS --------------------------------------------------------------------------------
# Points the app's hostname at its ALB. The zone is shared with other groups, so changes are limited to
# our name: the name itself, names under it (*.name) and ExternalDNS's ownership TXT records, which it
# names <record type>-<name> (e.g. a-merlion-staging.sctp-sandbox.com). Listed by type, not as
# *-<name>, which would also match someone else's other-merlion-staging.sctp-sandbox.com.
data "aws_iam_policy_document" "external_dns" {
  #checkov:skip=CKV_AWS_356:route53:ListHostedZones has no resource-level permissions; changes are limited to one zone and our record names
  statement {
    sid       = "ChangeOwnRecordsOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values = concat(
        [var.dns_name, "*.${var.dns_name}"],
        [for t in ["a", "aaaa", "cname", "txt"] : "${t}-${var.dns_name}"],
      )
    }
  }

  statement {
    sid       = "ReadTheZone"
    actions   = ["route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]
  }

  statement {
    sid       = "FindTheZone"
    actions   = ["route53:ListHostedZones", "route53:ListTagsForResources"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  name                 = "${var.name}-external-dns"
  assume_role_policy   = var.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "${var.name}-external-dns"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = var.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}
