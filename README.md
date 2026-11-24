# merlion-bank-infra

Terraform for Merlion Trust Bank (Bank of Anthos on Amazon EKS) in **us-east-1**
(ADR-006). Environments: staging and prod, in one shared AWS account, separated by their own
state bucket and KMS key, per-environment CI roles, and IAM guardrails (ADR-002).

> We are a 3-person team: one Solutions Architect, one DevSecOps engineer and one SRE.
> DevSecOps is the heaviest phase for Merlion Trust, because auditability and credential
> separation are hard constraints, so the one DevSecOps engineer owns both halves of it (the
> infrastructure foundations, and the data services and delivery pipelines). The SA and SRE
> review those PRs, and every PR is approved by someone other than its author.

| Path | What | Applied by |
|---|---|---|
| `bootstrap/` | State buckets + KMS keys (one per layer), GitHub OIDC provider lookup; `g4-merlion-ci-*` roles (`modules/iam-ci`); ECR; audit trail (`modules/audit`, ADR-004) | admin, once (see below) |
| `modules/` | kms, network, eks, rds, ecr, secrets, iam-ci, audit, addons, dns | - |
| `envs/{staging,prod}` | one root per environment, own state bucket and key | **pipeline only** |
| `.github/workflows/tf-plan.yml` | PR: gitleaks, fmt, validate, tflint, checkov, staging plan | GitHub Actions |
| `.github/workflows/tf-apply.yml` | main: apply staging -> plan prod -> approval -> apply prod | GitHub Actions |

## Staging

**https://merlion-staging.sctp-sandbox.com** (prod will be `merlion.sctp-sandbox.com`). The ALB only
answers for this hostname: its own `*.elb.amazonaws.com` address returns 404.

- `sctp-sandbox.com` is the course's shared Route 53 zone (`Z00541411T1NGPV97B5C0`). The **instructor
  allows groups to add their own records** to it. Other groups have records there, so IAM limits our
  CI roles and ExternalDNS to names under our own hostnames.
- The hostnames and the zone ID are defined once, in `modules/dns`. Bootstrap gives each CI role
  permission for its env's hostname; the env uses the same values for its certificate and ExternalDNS.
- Changing a hostname: change `modules/dns`, apply **bootstrap first** (admin), then let the pipeline
  apply the env. In the other order, the env apply fails with AccessDenied on the certificate's
  validation record.

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
| `g4-merlion-ci-record` | `merlion-bank-infra`, `main`, job without an environment (`deploy-record.yml`) | Add deploy records under `deploys/<env>/` in the audit bucket. Nothing else: no read, no delete. |

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

To receive console-write alerts (below), set an address when applying bootstrap and accept the
confirmation email AWS sends: `export TF_VAR_alert_email=<address>`.

## Restoring after the training account's nightly cleanup

The training account's nightly cleanup keeps resources tagged with our `Project` value, but still
strips every role's inline policies and policy attachments, the rules of the EKS-created cluster
security group, and the node group's Auto Scaling group. The roles can be assumed but do nothing: CI
fails with 403 on the state bucket, nodes can't join, the add-ons lose AWS access.

**Normally, the pipeline restores it** (`.github/workflows/restore.yml`). The restore role is stripped
too, and a role without permissions can't give itself any, so one person does one step first.
`scripts/restore.sh` does that step (only if the policy is missing), starts the workflow on `main`
and follows the run:

```bash
# An admin, your own profile for account 255945442255
AWS_PROFILE=<your profile> scripts/restore.sh                     # staging
AWS_PROFILE=<your profile> scripts/restore.sh prod                # waits for the production approval
AWS_PROFILE=<your profile> scripts/restore.sh staging "<reason>"  # if it isn't the nightly cleanup
```

By hand, the same is:

```bash
aws iam attach-role-policy --role-name g4-merlion-ci-restore \
  --policy-arn arn:aws:iam::255945442255:policy/g4-merlion-ci-restore
gh workflow run restore --repo merlion-trust-bank-sg/merlion-bank-infra --ref main -f environment=staging
```

The reason defaults to "nightly cleanup"; add `-f reason="..."` when it's something else.

1. **restore CI roles** (`g4-merlion-ci-restore`) re-attaches every CI role's policies. It can only
   attach the policies listed in its own policy (`modules/iam-ci/restore.tf`), one list per role: it
   can't write a policy or attach anything else. That's why the CI roles' policies are all managed
   policies, which the cleanup keeps, rather than inline ones, which it deletes.
2. **restore staging** (`g4-merlion-ci-staging`), or **plan prod** then **apply prod**
   (`g4-merlion-ci-prod-plan`, then `g4-merlion-ci-prod` after the `production` approval), if the
   cluster is up: puts back the cluster security group's rules, replaces a node group whose Auto
   Scaling group is gone, applies `main` (which re-attaches the env's own roles' policies), then
   refreshes the Kubernetes Secrets and restarts the bank. An env that's down is skipped; bring it up
   with tf-apply.

A prod restore goes through the same approval as any prod change, and `deploy-record` writes it to
`deploys/prod/` (`kind: infra-restore`, with the reason). The run doesn't recreate the console-write
alert's EventBridge rule (bootstrap); that waits for the next `bootstrap` apply.

**Fallbacks, from a person's account:**

| Situation | Who | Command (an admin, your own profile for account 255945442255) |
|---|---|---|
| The restore workflow can't run (e.g. its role or policy is gone); staging degraded | Any admin | `scripts/restore-iam.sh` |
| The same, prod degraded | **Break-glass holder only** (yqyeoh, cluster admin in prod) | `scripts/restore-iam.sh prod` |
| State bucket gone (the cleanup took more than IAM) | Any admin | `scripts/rebuild-bootstrap.sh` |

`restore-iam.sh` plans from an up-to-date `main` only. It applies on its own when the plan has only
known restore steps (stripped policies, the console-alert rule the cleanup deletes, and a node group
it replaces on purpose); anything else, such as another update or a destroy, waits for a `y`. It also puts back the cluster
security group's rules and replaces a node group whose Auto Scaling group is gone, then refreshes
the Kubernetes Secrets and restarts the bank.

**Prod from a person's account is break-glass:** prod changes normally go only through the approved
pipeline. A prod restore asks for a reason, refuses anyone but the break-glass holder, and writes a
record (reason, who, when, commit, what was applied) to `s3://g4-merlion-audit-255945442255/deploys/prod/`,
next to the pipeline's deploy records, where nobody can change or delete it. Afterwards, re-run any
CI job that failed with 403.

## Argo CD's GitHub credentials (once, by an org owner)

**Before the first merge that includes this, and before a new environment's first bootstrap:** the
environment's key must be stored (step 4). `bootstrap.sh` stops without it, so every `tf-apply` run
would fail at the bootstrap step.

Argo CD reads this repo as it would read a private one: with a GitHub App that can only read
`merlion-bank-infra` (why: ADR-007). The repo stays public because GitHub Free enforces rulesets and
environment required reviewers (the `production` approval) only on public repos; the credentials are
real either way (GitHub rejects a revoked key on a public repo too).

1. **Create the App:** org settings → Developer settings → GitHub Apps → New GitHub App.
   - Name `merlion-argocd`; Homepage URL: this repo; **Webhook: Active unticked**.
   - Repository permissions: **Contents: Read-only** (Metadata: Read-only is added automatically).
     Nothing else.
   - Where can this App be installed: **Only on this account**.
2. **Install it** (App page → Install App) on the org, **Only select repositories →
   `merlion-bank-infra`**. The installation ID is the number at the end of the installation page's URL.
3. **Generate two private keys** (App page → Private keys), one per environment, so either can be
   revoked alone.
4. **Store them**, as an admin in account 255945442255:

   ```bash
   deploy/bootstrap/put-argocd-github-app.sh staging <app id> <installation id> <staging key.pem>
   deploy/bootstrap/put-argocd-github-app.sh prod    <app id> <installation id> <prod key.pem>
   ```

   Then delete the `.pem` files. The secrets (`g4-merlion-<env>/argocd/github-app`) are outside
   Terraform, so they survive a teardown.

`bootstrap.sh` installs External Secrets, which copies the key into Argo CD's namespace as a
`repo-creds` Secret (`deploy/bootstrap/repo-creds.yaml`), then installs Argo CD. Argo CD then manages
both itself (`deploy/platform/<env>/external-secrets.yaml`, `argocd.yaml`). The pipeline never reads
the key. **Rotate:** generate a new key, run the script again, delete the old key on GitHub; Argo CD
picks it up within the hour.

## Region and change guardrails

Data residency (HC-1, ADR-006) and "no direct console changes" (HC-2) are enforced in three places:

| Guardrail | Where | What it stops |
|---|---|---|
| Region validation | `variable "region"` in `bootstrap/` and every `envs/*` root | Terraform refuses any region other than `us-east-1` |
| Region deny | `DenyOutsideApprovedRegion` in `modules/iam-ci/guardrails.tf`, on every CI role and every workload permissions boundary | Any API call outside `us-east-1` (global services such as IAM excepted) is denied, even if code asks for it |
| Console-write alert | `modules/console-alert`, applied from `bootstrap/` | A team member changing something in the AWS console: EventBridge matches the CloudTrail event and emails who, what, where and when |

The alert watches the team's own IAM users only (`team_iam_users` in `bootstrap/variables.tf`):
other groups share this account and use the console all the time. Console *views* don't alert,
only write calls. The rule runs in `us-east-1`, where our resources and global services such as
IAM are recorded.

## Pipeline

From a change on a laptop to production. `bootstrap/` is the only layer applied by hand; everything
in `envs/` goes through this pipeline. The one exception is a break-glass restore from a person's
account after the training account's nightly cleanup (above), used only when the restore workflow
can't run; it only puts back what's already on `main` and is recorded.

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

## Observability

Self-hosted in each cluster (ADR-003): Prometheus, Alertmanager and Grafana (kube-prometheus-stack),
Loki for logs, Grafana Alloy to collect pod logs, and YACE to copy CloudWatch metrics (ALB, RDS, the
audit log's Firehose) into Prometheus. Installed by Argo CD from `deploy/platform/<env>/`; our own
rules, alerts and dashboard are the `deploy/helm/observability` chart. The AWS side (Loki's bucket and
key, Pod Identity roles) is `modules/observability`, used by `envs/<env>/observability.tf`.

| | Staging | Prod |
|---|---|---|
| Grafana | https://grafana.merlion-staging.sctp-sandbox.com | https://grafana.merlion.sctp-sandbox.com |
| Logins | `admin` (team), `viewer` (read-only, for assessors) | same |
| Logs | Loki, chunks in S3 `g4-merlion-staging-loki` | S3 `g4-merlion-prod-loki` |
| Metrics | Prometheus, 15 days on an encrypted gp3 volume | same |
| Alerts | Telegram team group, labelled `environment=staging` | same group, `environment=prod` |

Everything stays in `us-east-1`; no logs or metrics leave the account. Telegram receives only alert
names, labels and the rule text, never log lines.

- **Logins and the bot token:** in Secrets Manager (`g4-merlion-<env>/monitoring/alerting`), written
  once per environment by `deploy/bootstrap/put-alert-secret.sh <env>` and copied into the cluster by
  External Secrets. Read a password with
  `aws secretsmanager get-secret-value --secret-id g4-merlion-<env>/monitoring/alerting --query SecretString --output text | jq -r .grafana_admin_password`.
- **SLOs:** 99.9% availability and p95 under 500 ms at the bank's ALB; definitions, error budget and
  policy in merlion-bank-app [`ops/slo/slo.md`](https://github.com/merlion-trust-bank-sg/merlion-bank-app/blob/main/ops/slo/slo.md).
- **Alerts:** `deploy/helm/observability/rules/bank-slo.rules.yaml` (burn-rate alerts for availability,
  p95 latency, a service with no pods, crash loops, a database with no connections, the audit log
  export), plus the chart's built-in Kubernetes alerts. A Watchdog message every 12 hours proves the
  path to Telegram works.
- **Incident runbook:** merlion-bank-app [`ops/runbooks/bank-service-down.md`](https://github.com/merlion-trust-bank-sg/merlion-bank-app/blob/main/ops/runbooks/bank-service-down.md);
  saved log and metric queries in `ops/queries/`.
- **Retention:** application logs 365 days (Loki and S3), metrics 15 days, Kubernetes audit log 365
  days in CloudWatch plus the Object Lock copy.

**Prod teardown and the log bucket.** Prod's Loki bucket keeps `force_destroy = false`, so Terraform
can't delete 365 days of logs by accident. Tearing prod down (the two-PR order in
`envs/prod/variables.tf`) therefore needs one manual step first: empty `g4-merlion-prod-loki`,
including old versions, since the bucket is versioned (S3 console: select the bucket, then
**Empty**). Otherwise the destroy stops at the bucket. Staging's bucket has `force_destroy = true`.

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
