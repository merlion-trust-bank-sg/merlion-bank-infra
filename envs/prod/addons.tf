# AWS side of the cluster add-ons (Pod Identity roles). The add-ons are installed by Argo CD from
# deploy/platform/; Argo CD itself is installed by the pipeline after this apply.
module "addons" {
  count = local.enabled ? 1 : 0

  source = "../../modules/addons"

  name                      = local.name
  region                    = var.region
  cluster_name              = module.eks[0].cluster_name
  permissions_boundary_arn  = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
  pod_identity_trust_policy = module.eks[0].pod_identity_trust_policy

  # External Secrets may read only the app's secrets: the RDS-managed master secrets and the JWT key
  # pair, decrypted with the env's key
  readable_secret_arns = concat(
    [for db in module.rds[0].databases : db.master_secret_arn],
    [aws_secretsmanager_secret.jwt[0].arn],
    # Alertmanager's Telegram token and Grafana's admin password (INF-16). Written once by
    # deploy/bootstrap/put-alert-secret.sh, outside Terraform, so it survives the nightly teardown.
    ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.name}/monitoring/alerting-??????"],
  )
  secrets_kms_key_arn = module.secretsmanager_key[0].arn

  # ExternalDNS may change only the app's own records in the course zone
  dns_zone_id = module.dns.zone_id
  dns_name    = local.app_hostname
}
