# Secrets for Bank of Anthos, read by External Secrets into Kubernetes Secrets.

# JWT signing key pair: userservice signs logins with the private key, the other services verify with
# the public key. Generated as an ephemeral key and written with write-only arguments, so the private
# key never appears in the Terraform plan or state. Bump the version to rotate it.
locals {
  jwt_key_version = 1
}

ephemeral "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_secretsmanager_secret" "jwt" {
  #checkov:skip=CKV2_AWS_57:Rotated by bumping jwt_key_version (it signs short-lived login tokens); there is no rotation Lambda
  name                    = "${local.name}/app/jwt"
  description             = "Bank of Anthos JWT signing key pair (PEM)"
  kms_key_id              = module.secretsmanager_key.arn
  recovery_window_in_days = 0 # environments are rebuilt daily; a deleted secret must not block the name
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id = aws_secretsmanager_secret.jwt.id
  secret_string_wo = jsonencode({
    private_key = ephemeral.tls_private_key.jwt.private_key_pem
    public_key  = ephemeral.tls_private_key.jwt.public_key_pem
  })
  secret_string_wo_version = local.jwt_key_version
}
