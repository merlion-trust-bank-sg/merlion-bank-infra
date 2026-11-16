output "topic_arn" {
  description = "SNS topic for console-write alerts; other alert paths (e.g. Alertmanager) can subscribe"
  value       = aws_sns_topic.alerts.arn
}

output "rule_arn" {
  value = aws_cloudwatch_event_rule.console_writes.arn
}
