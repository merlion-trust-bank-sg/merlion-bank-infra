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
