# One multi-region trail for the account (ADR-004). The account is shared, so it records every
# group's management events, including our CI roles' AssumeRoleWithWebIdentity with session names
# ci-<run id>-<attempt> that link back to the GitHub run.
resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252:No SNS topic per log file; delivery errors are watched with an alarm (INF-17)
  #checkov:skip=CKV2_AWS_10:CloudWatch Logs integration comes with the console-write alarm in INF-11
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.audit.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.audit.arn

  advanced_event_selector {
    name = var.include_read_management_events ? "Management events, read and write" : "Management events, write only"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }

    dynamic "field_selector" {
      for_each = var.include_read_management_events ? [] : [1]
      content {
        field  = "readOnly"
        equals = ["false"]
      }
    }
  }

  # Data events on the audit bucket itself, limited to reads, deletes and retention changes.
  # CloudTrail's own PutObject deliveries are left out, so the trail doesn't log its own writes.
  advanced_event_selector {
    name = "Audit bucket: reads, deletes, retention changes"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.audit.arn}/"]
    }

    field_selector {
      field  = "eventName"
      equals = ["GetObject", "DeleteObject", "DeleteObjects", "PutObjectRetention", "PutObjectLegalHold"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_s3_bucket_server_side_encryption_configuration.audit,
  ]
}
