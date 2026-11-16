# Alert when one of the team changes something in the AWS console (INF-11, HC-2: "no direct console
# changes to prod"). Everything we run is code applied by the pipeline or, for bootstrap, by an admin
# from Terraform, so a console write by a team member is either a mistake or a bypass.
#
# The account is shared with other groups, who use the console all the time, so the rule matches our
# own IAM users only. EventBridge receives CloudTrail management events directly, so there are no
# CloudWatch Logs ingestion costs. Write events only: viewing the console doesn't alert.

# --- Encrypted topic --------------------------------------------------------------------------
module "alerts_key" {
  source = "../kms"

  name        = "${var.name}-alerts"
  description = "${var.name} alert topic"

  # EventBridge publishes to the encrypted topic, so it needs the key (SNS uses it on its behalf)
  service_statements = [{
    sid     = "EventBridgePublishToEncryptedTopic"
    service = "events.amazonaws.com"
    actions = ["kms:GenerateDataKey*", "kms:Decrypt"]
  }]
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-console-writes"
  kms_master_key_id = module.alerts_key.arn
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "EventBridgeFromThisRuleOnly"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.console_writes.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Email subscription only when an address is given (set outside Git, e.g. TF_VAR_alert_email). AWS
# sends a confirmation email that has to be accepted once.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Rule ---------------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "console_writes" {
  name        = "${var.name}-console-writes"
  description = "Console write API calls by team members (no click-ops, HC-2)"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      sessionCredentialFromConsole = ["true"]
      readOnly                     = [false]
      userIdentity = {
        arn = var.watched_principal_arns
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.console_writes.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn

  # A short, readable message: who, what, where, when. No request parameters, so no data from the
  # call itself ends up in the email.
  input_transformer {
    input_paths = {
      who    = "$.detail.userIdentity.arn"
      source = "$.detail.eventSource"
      action = "$.detail.eventName"
      region = "$.detail.awsRegion"
      time   = "$.detail.eventTime"
      ip     = "$.detail.sourceIPAddress"
    }
    input_template = "\"Console change: <who> called <source> <action> in <region> at <time> from <ip>. Everything in this project is changed through Terraform and the pipeline; check CloudTrail and revert through code.\""
  }
}
