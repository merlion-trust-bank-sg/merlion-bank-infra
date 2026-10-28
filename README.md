# merlion-bank-infra

Terraform for Merlion Trust Bank (Bank of Anthos on Amazon EKS) in **us-east-1**
(ADR-006). Environments: dev, staging, prod, separated by IAM fence (ADR-002).

> As a 4-person team we doubled up on **DevSecOps**, the heaviest phase for Merlion
> Trust because auditability and credential separation are hard constraints. DO1
> owns the infrastructure foundations, DO2 owns data services and the delivery pipelines.

| Path | What | Applied by |
|---|---|---|
| `scripts/create-state-bucket.sh` | S3 state bucket (once) | admin, WSL |
| `bootstrap/` | OIDC provider, `gha-*` roles, ECR, audit trail | admin, WSL |
| `modules/` | kms, network, eks, rds, ecr, secrets, iam-ci, audit, addons | - |
| `envs/{dev,staging,prod}` | one root per environment, own state file | **pipeline only** |
| `.github/workflows/tf-plan.yml` | PR: gitleaks, fmt, tflint, checkov, plan comment | GitHub Actions |
| `.github/workflows/tf-apply.yml` | main: dev -> staging -> approval -> prod | GitHub Actions |

Workflow: `SCRUM-<n>-desc` branch -> PR (all checks + 1 review + CODEOWNERS) ->
squash merge -> `tf-apply` applies dev and staging, shows the prod plan, waits for
a `production` reviewer, applies prod.
