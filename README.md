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
| `.github/workflows/tf-plan.yml` | PR: gitleaks, fmt, validate, tflint, checkov, staging plan | GitHub Actions |
| `.github/workflows/tf-apply.yml` | main: apply staging -> plan prod -> approval -> apply prod | GitHub Actions |

## CI roles

GitHub Actions gets short-lived AWS credentials through OIDC. No access keys are stored anywhere.
Each role can be assumed by one exact kind of job (the OIDC `sub` claim):

| Role | Assumed by | Can |
|---|---|---|
| `g4-merlion-ci-build` | `merlion-bank-app`, push to `main` | Push images to the `merlion/*` ECR repos. Nothing else. |
| `g4-merlion-ci-plan` | `merlion-bank-infra`, pull requests | Read-only `terraform plan` for staging (staging state only) |
| `g4-merlion-ci-prod-plan` | `merlion-bank-infra`, `main`, job without an environment | Read-only `terraform plan` for prod (prod state only) |
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

## Pipeline

From a change on a laptop to production. `bootstrap/` is the only layer applied by hand; everything
in `envs/` goes through this pipeline.

1. **Branch:** `SCRUM-<n>-<desc>`, linked to the Jira issue.
2. **Pull request to `main`.** `tf-plan` runs on every push:

   | Check | Fails the PR when |
   |---|---|
   | gitleaks | A secret is committed |
   | `terraform fmt -check` | Code isn't formatted |
   | `terraform validate` | Invalid configuration in `bootstrap/` or an environment |
   | tflint | Invalid AWS values, unused declarations, missing versions |
   | checkov | Any security check fails. Exceptions are `#checkov:skip` comments with a reason, reviewed in the PR. |
   | `terraform plan` (staging) | Plan errors. The reviewer reads the plan in the job log. |

3. **Review:** one approval from someone other than the author, all checks green, conversations
   resolved (enforced by the `main` ruleset). Squash merge.
4. **`tf-apply` on `main`:**
   - **apply staging** (`g4-merlion-ci-staging`, GitHub environment `staging`)
   - **plan prod** (`g4-merlion-ci-prod-plan`, read-only). The plan is shown in the run summary and
     saved.
   - **apply prod** waits in the `production` environment until a required reviewer approves, then
     applies **that saved plan** with `g4-merlion-ci-prod`. Nothing else can change prod.

If prod has no changes, the run ends after the prod plan and asks for no approval.

### When a gate fails

- **A check fails on the PR:** the PR can't be merged. Fix the code and push again; the checks re-run.
  A checkov finding is fixed or, if it's an accepted risk, skipped next to the resource with a reason
  that the reviewer has to accept.
- **Staging apply fails after merge:** prod isn't touched (plan prod needs staging to succeed). Fix
  in a new PR.
- **The prod plan looks wrong:** reject the approval. Nothing is applied. Fix in a new PR.
- **A newer merge arrives while a prod approval is waiting:** approve the newer run. The older run
  refuses to apply (it isn't the latest commit, and its saved plan would be stale).

Every AWS call from the pipeline uses the role session name `ci-<run id>-<attempt>`, so CloudTrail
events link back to the GitHub run, its commit and its approver.

## Cost controls

Monthly estimate: `docs/cost-estimate.md` (DOC-05).

**Tags.** Every resource carries `Project`, `Team`, `Environment`, `ManagedBy` and `Stack`: from the
provider's `default_tags` for Terraform resources, the node launch template for EC2 instances,
volumes and ENIs, and `defaultTags` on the AWS Load Balancer Controller for ALBs, target groups and
their security groups. `Team = g4` also lets the CI roles tell our resources from other groups' in
the shared account.

**Staging teardown.** `.github/workflows/teardown.yml` destroys staging every day at 21:00 SGT, and
on demand with **Run workflow**. It first stops Argo CD and removes the workload namespaces, so the
LB Controller deletes its ALBs and the EBS CSI driver deletes the volumes, then runs
`terraform destroy`. Bring staging back with **Run workflow** on `tf-apply` (apply staging, then
Argo CD installs everything else). Running staging for working hours only costs about USD 90 a
month instead of about USD 280 (DOC-05).

**Budgets alert: not available.** The training account's learner policy explicitly denies AWS
Budgets and Cost Explorer (`budgets:*`, `ce:*`), and billing is handled by the organisation's
management account, so a Budgets alert per `Environment` tag can't be created from this account.
Spend is controlled with the tags above, the teardown and the estimate in DOC-05; in a real account,
an AWS Budgets alert on `Environment = prod` and `Environment = staging` would be added in `bootstrap/`.
