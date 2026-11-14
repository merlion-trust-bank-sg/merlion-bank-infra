# YACE reads the ALB's CloudWatch metrics for the SLOs (ADR-003). Read-only: it can list and read
# metrics and find resources by tag, nothing else.
data "aws_iam_policy_document" "yace" {
  #checkov:skip=CKV_AWS_356:CloudWatch metric reads and tag lookups don't support resource-level permissions
  statement {
    sid = "ReadCloudWatchMetrics"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "yace" {
  name                 = "${var.name}-yace"
  assume_role_policy   = var.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy" "yace" {
  name   = "${var.name}-yace"
  role   = aws_iam_role.yace.id
  policy = data.aws_iam_policy_document.yace.json
}

resource "aws_eks_pod_identity_association" "yace" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "yace"
  role_arn        = aws_iam_role.yace.arn
}
