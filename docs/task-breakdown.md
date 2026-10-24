# Merlion Trust Bank – Code Check-in Task Breakdown

Capstone: Cloud Infrastructure Engineering · Use Case A (Merlion Trust Bank) · Reference app: Google Bank of Anthos
Region: **`us-east-1`** (2 AZs: `us-east-1a`, `us-east-1b`) · Accounts: **dev / staging / prod** · Work tracking: **Jira SCRUM board**

> **Region note.** The brief's data-residency constraint names `ap-southeast-1`. Our instructor has directed us to deploy in **`us-east-1`**, so we treat the constraint as *"all customer data, backups and logs stay in one approved region"*.
> - Region is a single Terraform variable (`var.region`). Moving to Singapore is a variable change plus a redeploy.
> - This deviation is recorded in **ADR-006** together with the instructor's approval.
> - In the architecture diagram, rename the red boundary label from "ap-southeast-1 (Singapore)" to **"us-east-1"** (DOC-02).

---

## 1. Team & ownership

| Role | Member | Primary ownership | Main repo |
|---|---|---|---|
| Solutions Architect | **SA** – _name_ | Requirements, architecture diagram, service selection, constraint mapping, cost, ADRs, audit controls | `merlion-bank-infra` (docs + audit) |
| DevSecOps Engineer 1 | **DO1** – _name_ | Terraform foundations: state, OIDC roles, VPC, EKS; Helm chart & secrets wiring | `merlion-bank-infra` |
| DevSecOps Engineer 2 | **DO2** – _name_ | RDS, ECR, KMS, Secrets Manager, cluster add-ons, both CI/CD pipelines, security gates | `merlion-bank-app` |
| Site Reliability Engineer | **SRE** – _name_ | Self-hosted Prometheus, Loki, Grafana, Alertmanager; dashboards, SLO rules, alert routing, runbook, cost | Both |

> README note (required by brief): *"As a 4-person team we doubled up on **DevSecOps**, the heaviest phase for Merlion Trust because auditability and credential separation are hard constraints. DO1 owns the infrastructure foundations, DO2 owns data services and the delivery pipelines."*

**Everyone commits to both repos.** See the contribution matrix in [section 7](#7-contribution-matrix).

---

## 2. Target architecture (summary of the diagram)

| Layer | What we build |
|---|---|
| Delivery (outside AWS) | GitHub org `merlion-trust-bank-sg` · branches `SCRUM-<n>-*` · PR to `main` with 1 review · Actions: build → SCA → image scan · dev auto → staging auto after tests → **production manual approval** · Terraform plan shown on PR |
| Identity | GitHub OIDC → AWS STS. `gha-dev` / `gha-staging` can only touch their own account. `gha-prod` reaches the prod account only from the `production` environment, after approval. No stored keys |
| Accounts | **Dev** (EKS + RDS single-AZ, smallest sizes, auto-deploy on merge, scale to 0 overnight) · **Staging** (prod-like sizing, same Terraform modules, same image promoted, loadgenerator) · **Prod** |
| Network (prod) | VPC across 2 AZs. **Public subnets:** ALB (AWS Load Balancer Controller + ACM cert), NAT gateway. **Private subnets:** EKS. **Isolated DB subnets:** no internet route |
| Workload | 6 Bank of Anthos services built into our own images: `frontend` (2+ replicas), `userservice` (signs JWTs), `contacts`, `ledgerwriter`, `balancereader`, `transactionhistory` |
| Data | RDS PostgreSQL `accounts-db` and `ledger-db`: Multi-AZ, KMS-encrypted, automated backups, SQL over TLS |
| Platform services | ECR (immutable tags, scan on push) · Secrets Manager (DB creds, JWT key pair → pods via External Secrets/IRSA) · KMS CMKs (RDS, S3, logs, secrets) · Terraform state in S3 (versioned, encrypted) |
| Observability | **Self-hosted on EKS** in `us-east-1`, no third-party SaaS (namespace `monitoring`, `kube-prometheus-stack` + Loki Helm charts): **Loki + Promtail** (logs from all pods, chunks in S3 `us-east-1` + KMS, 365-day retention) · **Prometheus** (node, pod, app metrics on EBS; ALB metrics via **YACE** CloudWatch exporter) · **Grafana** (health, SLOs, logs for non-team viewers) · **Alertmanager** (SLO rules → email / Telegram) |
| Audit | CloudTrail in all 3 accounts → **S3 Object Lock, compliance mode, 1-year retention**. Also stores EKS audit logs and pipeline deploy records (who, what, when) |

---

## 3. Repositories

### 3.1 `merlion-bank-infra` – Terraform + architecture docs

```
merlion-bank-infra/
├── .github/
│   ├── workflows/
│   │   ├── tf-plan.yml            # PR: fmt, validate, tflint, checkov, plan per env -> PR comment
│   │   └── tf-apply.yml           # main: apply dev -> staging -> (approval) -> prod
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── bootstrap/                     # per account: state bucket, lock, GitHub OIDC provider
├── modules/
│   ├── kms/                       # CMKs: rds, s3, logs, secrets
│   ├── network/                   # VPC, 2 AZ public / private / isolated-db subnets, NAT, endpoints
│   ├── eks/                       # cluster, managed node group, IRSA, control-plane + audit logs
│   ├── rds/                       # accounts-db, ledger-db
│   ├── ecr/                       # one repo per service
│   ├── secrets/                   # Secrets Manager entries (DB creds, JWT key pair)
│   ├── iam-ci/                    # gha-dev, gha-staging, gha-prod OIDC roles
│   ├── audit/                     # CloudTrail + Object Lock bucket
│   ├── addons/                    # LB Controller, External Secrets
│   └── observability/             # Loki S3 bucket + IRSA, Helm releases (kube-prometheus-stack,
│                                  #   Loki, Promtail, YACE), Grafana dashboards JSON,
│                                  #   PrometheusRules (SLOs), Alertmanager routes
├── envs/
│   ├── dev/                       # root module, dev account
│   ├── staging/                   # root module, staging account
│   └── prod/                      # root module, prod account
├── docs/
│   ├── architecture/              # diagram source + PNG
│   ├── adr/
│   ├── requirements.md
│   ├── service-selection.md
│   ├── constraint-compliance.md
│   ├── cost-estimate.md
│   └── task-breakdown.md          # this file
└── README.md
```

### 3.2 `merlion-bank-app` – application, deployment, operations

```
merlion-bank-app/
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                 # PR: SCA, build, image scan (fail on HIGH/CRITICAL), gitleaks
│   │   └── cd.yml                 # main: push ECR -> dev -> tests -> staging -> approval -> prod
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── src/                           # Bank of Anthos upstream source, pinned release tag
├── deploy/
│   └── helm/bank-of-anthos/       # OUR chart (upstream manifests = reference only)
│       ├── templates/
│       ├── values-dev.yaml
│       ├── values-staging.yaml
│       └── values-prod.yaml
├── ops/
│   ├── slo/slo.md                 # SLIs, SLO targets, error budget
│   ├── runbooks/                  # incident runbook(s)
│   ├── queries/                   # saved LogQL / PromQL queries
│   └── demo/                      # failing-gate PR + alert trigger scripts
├── security/.trivyignore          # justified exceptions only, each with expiry
└── README.md                      # pipeline doc: SCRUM branch -> PR -> dev -> staging -> prod
```

---

## 4. Check-in rules (apply to both repos)

| Rule | Setting |
|---|---|
| Branch naming | `SCRUM-<n>-<short-desc>`, where `<n>` is the Jira issue number. This links commits and PRs to the Jira SCRUM board automatically. Example: `SCRUM-12-network-module` |
| Branch protection on `main` | No direct pushes (including admins), PR required, **≥1 approving review**, required status checks pass, conversation resolved |
| CODEOWNERS | `/modules/{network,eks,iam-ci}/**` → DO1 · `/modules/{rds,ecr,kms,secrets,addons}/**`, `/.github/**` → DO2 · `/modules/observability/**`, `/ops/**` → SRE · `/docs/**`, `/modules/audit/**` → SA |
| Reviewer | **Never the author**, and preferably from a different role (see "Reviewer" columns) |
| Commit messages | `SCRUM-<n>: <type>(<scope>): <summary>`. Example: `SCRUM-12: feat(network): add isolated DB subnets` |
| PR template | What changed · Why · Jira link · `terraform plan` / test evidence · Constraint impact (region / audit / retention / credentials) |
| GitHub Environments | `dev` (no gate) · `staging` (no gate, runs after dev tests) · `production` (**required reviewers**, only `main`) |
| Never commit | Secrets, kubeconfigs, `.terraform/`, state files, `*.tfvars` with secrets. gitleaks runs as a pre-commit hook and in CI |
| CI output hygiene | CI run logs are stored by GitHub, outside our AWS region. **No customer data and no app logs in CI output.** Smoke tests assert on status codes only |

---

## 5. Task breakdown

Replace `SCRUM-<n>` with the Jira issue number when you create the ticket.

### 5.1 `merlion-bank-infra`

| ID | Task | Owner | Branch | Key files | Depends on | Reviewer |
|---|---|---|---|---|---|---|
| INF-01 | Repo setup: branch protection, CODEOWNERS, PR template, `.gitignore`, gitleaks pre-commit, Jira link, README skeleton | DO1 | `SCRUM-<n>-repo-setup` | `.github/*`, `README.md` | – | SA |
| INF-02 | Bootstrap **each account** (dev, staging, prod): S3 state bucket (versioned, KMS), lock table, GitHub OIDC provider | DO1 | `SCRUM-<n>-bootstrap` | `bootstrap/` | INF-01 | SRE |
| INF-03 | OIDC roles `gha-dev`, `gha-staging`, `gha-prod`. Trust is pinned to `repo:merlion-trust-bank-sg/*` + environment; `gha-prod` trusts only `environment:production`; each role is scoped to its own account | DO1 | `SCRUM-<n>-oidc-roles` | `modules/iam-ci/` | INF-02 | SA |
| INF-04 | KMS module: CMKs for RDS, S3 (state + audit), CloudWatch Logs, Secrets Manager; key policies, rotation on | DO2 | `SCRUM-<n>-kms` | `modules/kms/` | INF-02 | DO1 |
| INF-05 | Network: VPC across **2 AZs (`us-east-1a`, `us-east-1b`)**. Public subnets (ALB, NAT), private subnets (EKS), **isolated DB subnets with no internet route**, VPC endpoints (ECR, S3, Secrets Manager, Logs, STS). 1 NAT in dev/staging | DO1 | `SCRUM-<n>-network` | `modules/network/` | INF-02 | SA |
| INF-06 | EKS: cluster in private subnets, managed node group, IRSA, control-plane logs **including `audit`** → CloudWatch | DO1 | `SCRUM-<n>-eks` | `modules/eks/` | INF-05 | SRE |
| INF-07 | RDS: `accounts-db` and `ledger-db` PostgreSQL in isolated DB subnets. Multi-AZ in staging/prod, single-AZ in dev. KMS encryption, automated backups, `rds.force_ssl = 1`, SG allows only EKS nodes | DO2 | `SCRUM-<n>-rds` | `modules/rds/` | INF-04, INF-05 | DO1 |
| INF-08 | ECR: one repo per service, **immutable tags**, scan on push, lifecycle policy. Promotion model (central vs per-account) per ADR-007 | DO2 | `SCRUM-<n>-ecr` | `modules/ecr/` | INF-02 | DO1 |
| INF-09 | Secrets Manager: DB credentials (RDS-managed master secret) and JWT key pair, KMS-encrypted. Read access only for the External Secrets IRSA role | DO2 | `SCRUM-<n>-secrets` | `modules/secrets/` | INF-04, INF-07 | SRE |
| INF-10 | Audit: CloudTrail in **all 3 accounts** (management + data events for audit bucket) → S3 bucket with **Object Lock compliance mode, 365 days**, log file validation, bucket policy denying delete/`PutBucketObjectLockConfiguration` to engineering roles; prefixes for EKS audit logs and pipeline deploy records | SA | `SCRUM-<n>-audit-trail` | `modules/audit/` | INF-04 | DO1 |
| INF-11 | Region guardrail: `var.region = "us-east-1"` in every env root; deny-other-regions policy on CI roles; CloudTrail alarm on console write events in prod | SA | `SCRUM-<n>-region-guardrail` | `modules/iam-ci/`, `envs/*/providers.tf` | INF-03, INF-10 | DO1 |
| INF-12 | Env roots `envs/dev`, `envs/staging`, `envs/prod` wiring all modules. Separate state per account; dev smallest sizes, staging prod-like | DO1 | `SCRUM-<n>-env-roots` | `envs/` | INF-04…10 | DO2 |
| INF-13 | Infra pipeline. **PR:** fmt / validate / tflint / **checkov (fail on HIGH)** / `plan` per env posted as PR comment. **main:** apply dev (`gha-dev`) → staging (`gha-staging`) → **manual approval** → prod (`gha-prod`) | DO2 | `SCRUM-<n>-tf-pipeline` | `.github/workflows/tf-*.yml` | INF-03, INF-12 | DO1 |
| INF-14 | Cluster add-ons part 1: **AWS Load Balancer Controller** (IRSA), **ACM certificate** for the ALB, **External Secrets Operator** (IRSA → Secrets Manager) | DO2 | `SCRUM-<n>-addons-lb-eso` | `modules/addons/` | INF-06, INF-09 | SRE |
| INF-15 | Monitoring stack in namespace `monitoring` via Helm (Terraform `helm_release`, pinned chart versions): **kube-prometheus-stack** (Prometheus on EBS PV, node-exporter, kube-state-metrics, Grafana, Alertmanager), **Loki** with chunks in an **S3 bucket in `us-east-1`** (KMS, IRSA, compactor retention **365 days**), **Promtail** DaemonSet (or Grafana Alloy, Promtail's successor), **YACE** exporter (IRSA, read-only CloudWatch) for ALB 5xx / `TargetResponseTime`. Grafana exposed via ALB ingress with login, admin password from Secrets Manager | SRE | `SCRUM-<n>-monitoring-stack` | `modules/observability/` | INF-06, INF-04, INF-14 | DO2 |
| INF-16 | Alert routing: **Alertmanager** receivers for **email** (SMTP) and **Telegram** (native `telegram_configs`). Bot token + SMTP creds via External Secrets, never in values files. Alert templates carry metric names and thresholds only, **no customer data**. Include a `Watchdog` / dead-man's-switch alert so a down Prometheus is noticed | SRE | `SCRUM-<n>-alertmanager-routing` | `modules/observability/` | INF-15 | DO2 |
| INF-17 | **Grafana dashboard** ("is the system healthy right now?"): SLO status + error budget, ALB requests / 5xx / p95, pod and node CPU and memory, Loki log panel per service. Provisioned as JSON (dashboards-as-code). **PrometheusRules** for SLOs: availability burn rate, p95 > 500 ms, plus pod CrashLoop / DB unreachable | SRE | `SCRUM-<n>-grafana-slo-rules` | `modules/observability/` | INF-15, INF-16, APP-13 | SA |
| INF-18 | Cost controls: tagging standard, AWS Budgets alert per account, **dev scale-to-0 overnight** (scheduled node group scaling), teardown workflow | SRE | `SCRUM-<n>-cost-controls` | `envs/dev/`, `.github/workflows/teardown.yml` | INF-12 | SA |

### 5.2 Docs and ADRs (`merlion-bank-infra/docs`)

| ID | Task | Owner | Branch | Reviewer |
|---|---|---|---|---|
| DOC-01 | Business requirements summary: functional, non-functional, constraints, assumptions (including the region directive) | SA | `SCRUM-<n>-requirements` | SRE |
| DOC-02 | Architecture diagram: update the region label to `us-east-1` and keep it matching what's deployed | SA | `SCRUM-<n>-architecture-diagram` | DO1 |
| DOC-03 | Service selection: chosen vs alternative vs why (EKS, RDS, GitHub Actions, Prometheus/Loki/Grafana, Secrets Manager) | SA | `SCRUM-<n>-service-selection` | DO2 |
| DOC-04 | Constraint compliance mapping: constraint → decision → evidence (see [section 8](#8-hard-constraint-traceability)) | SA | `SCRUM-<n>-compliance-map` | SRE |
| DOC-05 | Monthly prod cost estimate with `us-east-1` pricing (EKS, nodes incl. monitoring stack, 2× Multi-AZ RDS, NAT, ALB, EBS for Prometheus, S3 for Loki + audit, CloudTrail, YACE CloudWatch API calls) plus dev/staging run cost | SA | `SCRUM-<n>-cost-estimate` | SRE |
| DOC-06 | ADR-001 Runtime: EKS vs ECS | SA | `SCRUM-<n>-adr-001-runtime` | DO1 |
| DOC-07 | ADR-002 Multi-account dev/staging/prod vs single account | DO1 | `SCRUM-<n>-adr-002-accounts` | SA |
| DOC-08 | ADR-003 Observability: **self-hosted Prometheus + Loki + Grafana + Alertmanager on EKS** (chosen) vs CloudWatch (alternative) vs Grafana Cloud (rejected: SaaS, data outside our region). Consequences: data stays in `us-east-1`, open-source skills from the labs, no per-GB ingest fees; but we operate it ourselves (single replicas, so a Watchdog alert is needed), and ALB metrics still come from CloudWatch via YACE | SRE | `SCRUM-<n>-adr-003-observability` | SA |
| DOC-09 | ADR-004 Audit log immutability: S3 Object Lock compliance mode, 1 year | SA | `SCRUM-<n>-adr-004-audit` | DO1 |
| DOC-10 | ADR-005 Credentials: GitHub OIDC per environment, no static keys | DO1 | `SCRUM-<n>-adr-005-oidc` | DO2 |
| DOC-11 | ADR-006 Region: `us-east-1` per instructor directive (deviation from the brief, approval recorded, region parameterised) | SA | `SCRUM-<n>-adr-006-region` | SRE |
| DOC-12 | ADR-007 Image promotion: build once, promote the same digest dev → staging → prod (central ECR vs per-account copy) | DO2 | `SCRUM-<n>-adr-007-promotion` | DO1 |

### 5.3 `merlion-bank-app`

| ID | Task | Owner | Branch | Key files | Depends on | Reviewer |
|---|---|---|---|---|---|---|
| APP-01 | Repo setup: branch protection, CODEOWNERS, PR template, GitHub Environments `dev`, `staging`, `production` (prod requires reviewers) | DO2 | `SCRUM-<n>-repo-setup` | `.github/*` | – | DO1 |
| APP-02 | Vendor Bank of Anthos source at a pinned release tag into `src/`, recording the upstream commit in README | DO2 | `SCRUM-<n>-import-source` | `src/`, `README.md` | APP-01 | SA |
| APP-03 | Build images for the **6 services** (+ `loadgenerator` for staging), tagged with git SHA, pushed by digest | DO2 | `SCRUM-<n>-image-builds` | `ci.yml` | APP-02, INF-08 | DO1 |
| APP-04 | **Security gate 1 – SCA:** Trivy `fs` / OWASP dependency-check on Python + Java deps, **fail on HIGH/CRITICAL**, exit code not suppressed | DO2 | `SCRUM-<n>-sca-gate` | `ci.yml` | APP-03 | SRE |
| APP-05 | **Security gate 2 – image scan:** Trivy image `--exit-code 1 --severity HIGH,CRITICAL`, blocks push to ECR | DO2 | `SCRUM-<n>-image-scan-gate` | `ci.yml`, `security/.trivyignore` | APP-03 | SRE |
| APP-06 | Secret scanning: gitleaks in CI | DO1 | `SCRUM-<n>-gitleaks` | `ci.yml` | APP-01 | DO2 |
| APP-07 | Helm chart (our own): 6 Deployments + Services, **`frontend` ≥ 2 replicas**, probes, requests/limits, PDBs, HPA on `frontend`. Ingress `ingressClassName: alb` with ACM cert and HTTPS 443. DB endpoints → RDS over TLS | DO1 | `SCRUM-<n>-helm-chart` | `deploy/helm/` | APP-03, INF-07, INF-14 | DO2 |
| APP-08 | Secrets wiring: `ExternalSecret` objects for DB creds + JWT key pair → Kubernetes Secrets → pods. Nothing in values files or images | DO1 | `SCRUM-<n>-external-secrets` | `deploy/helm/templates/externalsecret.yaml` | APP-07, INF-09, INF-14 | SRE |
| APP-09 | Env values: `values-dev` (1 replica, smallest), `values-staging` (prod-like, `loadgenerator` on), `values-prod` | DO1 | `SCRUM-<n>-env-values` | `deploy/helm/values-*.yaml` | APP-07 | SA |
| APP-10 | CD pipeline: merge to `main` → build + gates → push → **dev** (`gha-dev`) auto → smoke tests → **staging** (`gha-staging`) auto, same digest → **manual approval** → **prod** (`gha-prod`) | DO2 | `SCRUM-<n>-cd-pipeline` | `cd.yml` | APP-05, APP-09, INF-03 | DO1 |
| APP-11 | Deploy audit record: on every prod deploy, the pipeline writes `{actor, approver, PR, commit SHA, image digest, env, timestamp}` to the Object Lock bucket | SA | `SCRUM-<n>-deploy-audit` | `cd.yml` | APP-10, INF-10 | DO2 |
| APP-12 | Pipeline README: SCRUM branch → PR → dev → staging → prod; approvals; **what happens when a security gate fails**; CI-log hygiene note | DO2 | `SCRUM-<n>-pipeline-readme` | `README.md` | APP-10 | SA |
| APP-13 | Logging check: all 6 services log to stdout, visible in Loki per service (`{namespace="bank", app="<service>"}`). Save LogQL queries (errors per service, failed logins, ledger write failures) | SRE | `SCRUM-<n>-log-queries` | `ops/queries/` | APP-10, INF-15 | DO1 |
| APP-14 | SLIs and SLOs: **availability** = 1 − ALB 5xx ratio (target 99.9%); **p95 latency** = ALB `TargetResponseTime` p95 (target < 500 ms). Justification + error budget | SRE | `SCRUM-<n>-slo` | `ops/slo/slo.md` | APP-13 | SA |
| APP-15 | Incident runbook, e.g. "ledger-db failover / connection errors": detection (Alertmanager alert), diagnosis (Grafana dashboard, LogQL in Loki, RDS events), mitigation, escalation | SRE | `SCRUM-<n>-runbook` | `ops/runbooks/` | INF-17 | DO1 |
| APP-16 | Demo prep: failing-gate PR (vulnerable base image), alert trigger (scale `frontend` to 0 or break a DB secret in staging), audit trail walkthrough for the last prod deploy | SRE + DO2 | `SCRUM-<n>-demo-scripts` | `ops/demo/` | APP-05, INF-17, APP-11 | SA |

---

## 6. Check-in sequence (suggested 4 weeks)

| Week | `merlion-bank-infra` | `merlion-bank-app` | Docs |
|---|---|---|---|
| **1 – Foundations** | INF-01, INF-02, INF-03, INF-04, INF-05 | APP-01, APP-02 | DOC-01, DOC-06, DOC-07, DOC-11 |
| **2 – Platform** | INF-06, INF-07, INF-08, INF-09, INF-10, INF-11, INF-12, INF-13 | APP-03, APP-04, APP-05, APP-06 | DOC-03, DOC-10, DOC-12 |
| **3 – Deploy + observe** | INF-14, INF-15, INF-16 | APP-07, APP-08, APP-09, APP-10, APP-11, APP-13 | DOC-08, DOC-09 |
| **4 – Operate + harden** | INF-17, INF-18 | APP-12, APP-14, APP-15, APP-16 | DOC-02 final (matches deployed), DOC-04, DOC-05, final README |

**Critical path:** INF-02 → INF-03 → INF-05 → INF-06 → INF-14 → APP-07 → APP-10 (prod running) → INF-15 → INF-17 → live alert demo.

---

## 7. Contribution matrix

Number of PRs each member authors in each repo:

| Member | `merlion-bank-infra` | `merlion-bank-app` | Docs / ADRs | Total |
|---|---|---|---|---|
| SA | 2 (INF-10, 11) | 1 (APP-11) | 8 (DOC-01–06, 09, 11) | 11 |
| DO1 | 6 (INF-01, 02, 03, 05, 06, 12) | 4 (APP-06–09) | 2 (DOC-07, 10) | 12 |
| DO2 | 6 (INF-04, 07, 08, 09, 13, 14) | 7 (APP-01–05, 10, 12) | 1 (DOC-12) | 14 |
| SRE | 4 (INF-15–18) | 4 (APP-13–16) | 1 (DOC-08) | 9 |

Each member also **reviews** roughly 10–12 PRs, so the review history shows cross-role collaboration.

---

## 8. Hard-constraint traceability

| Constraint | Check-in that satisfies it | Evidence to show |
|---|---|---|
| **Data residency** (one approved region: `us-east-1` per instructor) | INF-05/07 (VPC, RDS, backups in-region, no cross-region copy), INF-11 (region pin + deny), INF-15 (self-hosted Loki/Prometheus, Loki chunks in S3 `us-east-1`, no SaaS), CI-log hygiene rule | `terraform state show` region, RDS backup config, Loki bucket region, ADR-003, ADR-006 |
| **Auditability** (every prod change traceable) | Branch protection + SCRUM links (INF-01/APP-01), plan on PR (INF-13), prod approval (APP-10), deploy record (APP-11), CloudTrail incl. OIDC role sessions (INF-10) | Jira ticket → PR → reviewer → Actions run → approver → deploy record → CloudTrail `AssumeRoleWithWebIdentity` event |
| **Audit log retention 1 yr, tamper-proof** | INF-10 Object Lock **compliance mode** 365 days, delete denied to engineering roles | Bucket Object Lock config, a failed `DeleteObject` attempt, ADR-004 |
| No console changes to prod | INF-03 (`gha-prod` only from `production` environment), INF-11 (console-write alarm) | IAM trust policy, CloudTrail query |
| Credential separation | INF-03 per-account roles, APP-10 assumes a different role per stage | `gha-staging` trying a prod action → `AccessDenied` |
| Security gates block | APP-04, APP-05, INF-13 checkov | Demo PR with a failing scan (APP-16) |

---

## 9. Definition of done for every PR

- [ ] Branch named `SCRUM-<n>-*` and linked to a Jira issue
- [ ] Reviewed and approved by someone who isn't the author
- [ ] CI green (fmt/lint/checkov/plan, or build/SCA/image scan/gitleaks)
- [ ] No secrets; region only via `var.region` (`us-east-1`)
- [ ] Docs, ADRs or diagram updated if the design changed
- [ ] Infra: `terraform plan` attached to the PR, nothing applied manually
