# merlion-bank-infra

Terraform for Merlion Trust Bank (Bank of Anthos on Amazon EKS) in **us-east-1**
(ADR-006). Environments: staging and prod, in one shared AWS account, separated by their own
state bucket and KMS key, per-environment CI roles, and IAM guardrails (ADR-002).

> As a 4-person team we doubled up on **DevSecOps**, the heaviest phase for Merlion
> Trust because auditability and credential separation are hard constraints. DO1
> owns the infrastructure foundations, DO2 owns data services and the delivery pipelines.

| Path | What | Applied by |
|---|---|---|
| `bootstrap/` | State buckets + KMS keys (one per layer), GitHub OIDC provider lookup; `g4-merlion-ci-*` roles (`modules/iam-ci`); later ECR, audit trail | admin, once (see below) |
| `modules/` | kms, network, eks, rds, ecr, secrets, iam-ci, audit, addons | - |
| `envs/{staging,prod}` | one root per environment, own state bucket and key | **pipeline only** |
| `.github/workflows/tf-plan.yml` | PR: gitleaks, fmt, tflint, checkov, plan comment | GitHub Actions |
| `.github/workflows/tf-apply.yml` | main: staging -> approval -> prod | GitHub Actions |

Workflow: `SCRUM-<n>-desc` branch -> PR (all checks + 1 review; CODEOWNERS suggests reviewers) ->
squash merge -> `tf-apply` applies staging, shows the prod plan, waits for a `production`
reviewer, applies prod.

## CI roles

GitHub Actions gets short-lived AWS credentials through OIDC. No access keys are stored anywhere.
Each role can be assumed by one exact kind of job (the OIDC `sub` claim):

| Role | Assumed by | Can |
|---|---|---|
| `g4-merlion-ci-build` | `merlion-bank-app`, push to `main` | Push images to the `merlion/*` ECR repos. Nothing else. |
| `g4-merlion-ci-plan` | `merlion-bank-infra`, pull requests | Read-only `terraform plan` for staging (staging state only) |
| `g4-merlion-ci-staging` | `merlion-bank-infra`, GitHub environment `staging` | Change staging resources only |
| `g4-merlion-ci-prod` | `merlion-bank-infra`, GitHub environment `production`, after a reviewer approves | Change prod resources only |

App deploys go through Argo CD, which pulls from this repo, so the app repo never gets
staging or prod credentials.

What stops the staging and prod roles from going further:

- **Least privilege:** a deploy policy scoped to the environment's own resources, instead of
  `AdministratorAccess`
- **Environment fence:** deny anything tagged with another `Environment` (or `shared`), anything
  named for the other environment, and the other environment's state bucket and key
- **Permissions boundary:** every IAM role the pipeline creates must carry
  `g4-merlion-<env>-workload-boundary`, so a new role can't be used to escalate
- **Bootstrap protection:** no changes to the state buckets and keys, CI roles, boundaries,
  ECR repos or the audit trail
- **Region lock:** every non-global action outside `us-east-1` is denied
- **Other teams:** no deleting resources that aren't tagged `Team=g4`, and no changes to
  resources tagged with another team

## Bootstrap (once, by an admin)

Bootstrap is already applied, and its state is in `g4-merlion-bootstrap-tfstate-255945442255`.
Changes are a normal plan and apply:

```bash
export AWS_PROFILE=<profile for account 255945442255>
cd bootstrap
terraform init && terraform plan -out=bootstrap.tfplan && terraform apply bootstrap.tfplan
```

In a brand-new account the state bucket doesn't exist yet: comment out the block in
`bootstrap/backend.tf`, apply with local state, uncomment it, then `terraform init -migrate-state`.

State buckets are protected by `prevent_destroy` and a bucket policy that denies `s3:DeleteBucket`
and `s3:DeleteObjectVersion` to everyone, so they outlive environment teardowns.
