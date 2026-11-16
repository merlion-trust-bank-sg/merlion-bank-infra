# AWS side of the cluster add-ons (Pod Identity roles). The add-ons are installed by Argo CD from
# deploy/platform/; Argo CD itself is installed by the pipeline after this apply.
module "addons" {
  source = "../../modules/addons"

  name                      = local.name
  region                    = var.region
  cluster_name              = module.eks.cluster_name
  permissions_boundary_arn  = "arn:aws:iam::${var.account_id}:policy/${local.name}-workload-boundary"
  pod_identity_trust_policy = module.eks.pod_identity_trust_policy

  # External Secrets may read only these: the app's secrets (the RDS-managed master secrets and the
  # JWT key pair, decrypted with the env's key) and Argo CD's GitHub App credentials
  readable_secret_arns = concat(
    [for db in module.rds.databases : db.master_secret_arn],
    [aws_secretsmanager_secret.jwt.arn],
    # Written once by deploy/bootstrap/put-argocd-github-app.sh, outside Terraform, so it survives a
    # teardown (AWS-managed key). Secrets Manager adds a 6-character suffix to the ARN.
    ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.name}/argocd/github-app-??????"],
  )
  secrets_kms_key_arn = module.secretsmanager_key.arn

  # ExternalDNS may change only the app's own records in the course zone
  dns_zone_id = module.dns.zone_id
  dns_name    = local.app_hostname
}
