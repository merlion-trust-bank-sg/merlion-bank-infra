# One multi-region trail for the account (ADR-004). The account is shared, so it records every
# group's write management events. Our CI roles' calls carry session names ci-<run id>-<attempt>
# that link back to the GitHub run (AssumeRoleWithWebIdentity itself is a read event, so it's only
# recorded with include_read_management_events = true).
resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252:No SNS topic per log file; delivery errors are watched with an alarm (INF-17)
  #checkov:skip=CKV2_AWS_10:No CloudWatch Logs copy: console-write alerts use EventBridge (modules/console-alert, INF-11), which needs no log ingestion
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
  # PutObject is left out here, so the trail doesn't log its own deliveries; deploy record writes
  # are logged by the next selector.
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

  # Deploy record writes (deploys/<env>/) and EKS audit log deliveries (eks-audit/), so CloudTrail
  # shows which role wrote each object. Only these prefixes: CloudTrail delivers under AWSLogs/, and
  # logging its own writes would add an event for every delivery, endlessly.
  advanced_event_selector {
    name = "Audit bucket: deploy record and EKS audit log writes"

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
      starts_with = ["${aws_s3_bucket.audit.arn}/deploys/", "${aws_s3_bucket.audit.arn}/eks-audit/"]
    }

    field_selector {
      field  = "eventName"
      equals = ["PutObject"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_s3_bucket_server_side_encryption_configuration.audit,
  ]
}
