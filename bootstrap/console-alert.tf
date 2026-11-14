# Alert on console changes by the team (INF-11, HC-2). In bootstrap, like the audit trail: the
# pipeline must not be able to switch it off.
module "console_alert" {
  source = "../modules/console-alert"

  name                   = local.prefix
  watched_principal_arns = [for u in var.team_iam_users : "arn:aws:iam::${var.account_id}:user/${u}"]
  alert_email            = var.alert_email
}
