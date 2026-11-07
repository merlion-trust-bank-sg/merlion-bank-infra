# merlion-bank-infra

Terraform for Merlion Trust Bank (Bank of Anthos on Amazon EKS) in **us-east-1**
(ADR-006). Environments: dev, staging, prod, separated by IAM fence (ADR-002).

> As a 4-person team we doubled up on **DevSecOps**, the heaviest phase for Merlion
> Trust because auditability and credential separation are hard constraints. DO1
> owns the infrastructure foundations, DO2 owns data services and the delivery pipelines.

| Path | What | Applied by |
|---|---|---|
| `bootstrap/` | State buckets + KMS keys (one per layer), GitHub OIDC provider lookup; later the `g4-merlion-ci-*` roles, ECR, audit trail | admin, once (see below) |
| `modules/` | kms, network, eks, rds, ecr, secrets, iam-ci, audit, addons | - |
| `envs/{staging,prod}` | one root per environment, own state bucket and key | **pipeline only** |
| `.github/workflows/tf-plan.yml` | PR: gitleaks, fmt, tflint, checkov, plan comment | GitHub Actions |
| `.github/workflows/tf-apply.yml` | main: dev -> staging -> approval -> prod | GitHub Actions |

Workflow: `SCRUM-<n>-desc` branch -> PR (all checks + 1 review + CODEOWNERS) ->
squash merge -> `tf-apply` applies dev and staging, shows the prod plan, waits for
a `production` reviewer, applies prod.

## Bootstrap (once, by an admin)

The state buckets are created by `bootstrap/` itself, so the first apply uses local state:

```bash
export AWS_PROFILE=<profile for account 255945442255>
cd bootstrap
terraform init && terraform plan -out=bootstrap.tfplan && terraform apply bootstrap.tfplan
# uncomment the backend block in bootstrap/backend.tf, then:
terraform init -migrate-state      # answer "yes"
rm -f terraform.tfstate terraform.tfstate.backup bootstrap.tfplan
```

State buckets are protected by `prevent_destroy` and a bucket policy that denies `s3:DeleteBucket`
and `s3:DeleteObjectVersion` to everyone, so they outlive environment teardowns.
