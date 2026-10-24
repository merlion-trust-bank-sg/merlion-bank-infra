# Merlion Trust Bank – Code Check-in Task Breakdown

Capstone: Cloud Infrastructure Engineering · Use Case A (Merlion Trust Bank) · Reference app: Google Bank of Anthos · Region: `ap-southeast-1` only

---

## 1. Team & ownership

| Role | Member | Primary ownership | Main repo |
|---|---|---|---|
| Solutions Architect | **SA** – _name_ | Requirements, architecture diagram, service selection, constraint mapping, cost, ADRs, audit/compliance controls | `merlion-infra` (docs + audit) |
| DevSecOps Engineer 1 | **DO1** – _name_ | Terraform: state, network, EKS, RDS, ECR, IAM/OIDC, infra pipeline | `merlion-infra` |
| DevSecOps Engineer 2 | **DO2** – _name_ | Container builds, Helm chart, app CI/CD, security gates, secrets delivery | `merlion-app` |
| Site Reliability Engineer | **SRE** – _name_ | Logging, metrics, dashboards, SLOs, alerts, runbook, cost teardown | Both |

> README note (required by brief): *"As a 4-person team we doubled up on **DevSecOps** — the heaviest phase for Merlion Trust because auditability and credential separation are hard constraints. DO1 owns the infrastructure pipeline, DO2 owns the application pipeline."*

**Everyone commits to both repos.** The brief says that a history where one person authored everything will be questioned. See the contribution matrix in [section 7](#7-contribution-matrix).

---

## 2. Repositories

### 2.1 `merlion-infra` – infrastructure as code + architecture docs

```
merlion-infra/
├── .github/
│   ├── workflows/
│   │   ├── tf-plan.yml            # PR: fmt, validate, checkov, plan -> PR comment
│   │   └── tf-apply.yml           # main: apply staging -> approval -> apply prod
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── bootstrap/                     # one-off: S3 state bucket, DynamoDB lock, GitHub OIDC provider
├── modules/
│   ├── network/                   # VPC, private subnets, NAT, VPC endpoints
│   ├── eks/                       # cluster, node groups, IRSA
│   ├── rds/                       # PostgreSQL (accounts-db, ledger-db), KMS, backups
│   ├── ecr/                       # repos + scan-on-push + immutable tags
│   ├── iam-ci/                    # per-env GitHub OIDC roles (staging cannot touch prod)
│   ├── audit/                     # CloudTrail + S3 Object Lock (1 yr, compliance mode)
│   └── observability/             # Loki S3 bucket, IRSA roles, retention
├── envs/
│   ├── staging/                   # root module, own state key
│   └── prod/                      # root module, own state key
├── platform/                      # cluster add-ons via helm_release
│   ├── ingress-nginx/
│   ├── external-secrets/
│   └── monitoring/                # kube-prometheus-stack, Loki, Promtail/Alloy values
├── docs/
│   ├── architecture/              # diagram (.drawio + .png)
│   ├── adr/                       # ADR-001 ... ADR-00n
│   ├── requirements.md
│   ├── service-selection.md
│   ├── constraint-compliance.md
│   └── cost-estimate.md
└── README.md
```

### 2.2 `merlion-app` – application, deployment, operations

```
merlion-app/
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                 # PR: SCA scan, build, image scan (fail on HIGH/CRITICAL)
│   │   └── cd.yml                 # main: push ECR -> deploy staging -> approval -> deploy prod
│   ├── CODEOWNERS
│   └── pull_request_template.md
├── src/                           # Bank of Anthos upstream source (vendored, pinned tag)
├── docker/                        # team-owned Dockerfiles / build overrides if needed
├── deploy/
│   └── helm/bank-of-anthos/       # OUR chart (upstream manifests = reference only)
│       ├── templates/
│       ├── values-staging.yaml
│       └── values-prod.yaml
├── ops/
│   ├── dashboards/                # Grafana JSON
│   ├── alerts/                    # PrometheusRule YAML
│   ├── slo/slo.md                 # SLIs, SLO targets, error budget
│   └── runbooks/                  # incident runbook(s)
├── security/
│   └── .trivyignore               # justified exceptions only, each with expiry
└── README.md                      # pipeline doc: feature -> PR -> staging -> prod, failed gate handling
```

---

## 3. Check-in rules (apply to both repos)

| Rule | Setting |
|---|---|
| Branching model | Trunk-based: `main` is protected; short-lived `feature/<id>-<desc>`, `fix/<id>-<desc>`, `docs/<id>-<desc>` |
| Branch protection on `main` | No direct pushes (including admins), PR required, **≥1 approving review**, required status checks pass, conversation resolved, linear history |
| CODEOWNERS | `/modules/**` → DO1 · `/platform/monitoring/**`, `/ops/**` → SRE · `/docs/**` → SA · `/.github/**`, `/deploy/**` → DO2 |
| Reviewer | **Never the author.** Reviewer comes from a different role where possible (see "Reviewer" columns) |
| Commit messages | Conventional commits: `feat(eks): add managed node group` · `fix(ci): fail on HIGH vulns` · `docs(adr): ADR-003 runtime` |
| PR template | What changed · Why · Linked task ID · `terraform plan` / test evidence · Constraint impact (residency / audit / retention) |
| Merging | Merge commits or squash with the PR number in the title, so every prod change traces to PR → reviewer → pipeline run (**auditability constraint**) |
| Never commit | Secrets, `.tfvars` with secrets, kubeconfigs, `.terraform/`, state files. Add `gitleaks` pre-commit hook + CI check |
| Prod environment | GitHub Environment `production` with required reviewers. Only the pipeline deploys to prod |

---

## 4. `merlion-infra` – task breakdown

Do these tasks roughly in order: each one's dependencies are listed in "Depends on".

| ID | Task | Owner | Branch | Key files | Depends on | Reviewer |
|---|---|---|---|---|---|---|
| INF-01 | Create repo, branch protection, CODEOWNERS, PR template, `.gitignore`, gitleaks pre-commit, README skeleton | DO1 | `feature/inf-01-repo-setup` | `.github/*`, `README.md` | – | SA |
| INF-02 | Bootstrap: S3 state bucket (versioned, KMS, `ap-southeast-1`), DynamoDB lock table, GitHub OIDC provider | DO1 | `feature/inf-02-bootstrap` | `bootstrap/` | INF-01 | SRE |
| INF-03 | Per-env CI roles: `gh-infra-staging`, `gh-infra-prod`, `gh-app-staging`, `gh-app-prod`. Trust policy pinned to repo + environment; staging policies deny prod ARNs/tags | DO1 | `feature/inf-03-oidc-roles` | `modules/iam-ci/` | INF-02 | SA |
| INF-04 | Network module: VPC, 3 AZ private/public subnets, NAT, VPC endpoints (ECR, S3, Secrets Manager, Logs) | DO1 | `feature/inf-04-network` | `modules/network/` | INF-02 | SA |
| INF-05 | EKS module: cluster (private endpoint + restricted public), managed node group, IRSA, control-plane logging on | DO1 | `feature/inf-05-eks` | `modules/eks/` | INF-04 | SRE |
| INF-06 | RDS module: PostgreSQL for `accounts-db` and `ledger-db`, private subnets only, KMS encryption, automated backups in-region, **no cross-region snapshot copy** | DO2 | `feature/inf-06-rds` | `modules/rds/` | INF-04 | DO1 |
| INF-07 | ECR module: one repo per service, scan-on-push, immutable tags, lifecycle policy | DO2 | `feature/inf-07-ecr` | `modules/ecr/` | INF-02 | DO1 |
| INF-08 | Audit module: org/account CloudTrail → S3 with **Object Lock compliance mode 365 days**, bucket policy denying delete to engineering roles, CloudTrail log file validation | SA | `feature/inf-08-audit-trail` | `modules/audit/` | INF-02 | DO1 |
| INF-09 | Region guardrail: provider `region = "ap-southeast-1"` pinned, plus deny-other-regions IAM/SCP policy for app data services | SA | `feature/inf-09-region-guardrail` | `modules/iam-ci/`, `envs/*/providers.tf` | INF-03 | DO1 |
| INF-10 | Env root modules `envs/staging` and `envs/prod` wiring all modules, separate state keys, smaller sizing for staging | DO1 | `feature/inf-10-env-roots` | `envs/` | INF-04…08 | DO2 |
| INF-11 | Infra pipeline: PR → `fmt`/`validate`/`tflint`/**checkov (fail on HIGH)** → `plan` posted as PR comment; `main` → apply staging → **approval** → apply prod | DO2 | `feature/inf-11-tf-pipeline` | `.github/workflows/tf-*.yml` | INF-03, INF-10 | DO1 |
| INF-12 | Self-hosted GitHub runners in `ap-southeast-1` (EC2 or actions-runner-controller on EKS) so build/deploy logs and artifacts stay in Singapore; archive run logs to the Object Lock bucket | DO2 | `feature/inf-12-sg-runners` | `modules/ci-runners/` or `platform/arc/` | INF-05, INF-08 | SA |
| INF-13 | Platform add-ons: ingress-nginx, external-dns, External Secrets Operator (IRSA → Secrets Manager) | DO2 | `feature/inf-13-platform-addons` | `platform/` | INF-05 | SRE |
| INF-14 | Observability infra: Loki S3 bucket (`ap-southeast-1`, KMS, lifecycle = retention period), IRSA roles for Loki/Prometheus | SRE | `feature/inf-14-obs-storage` | `modules/observability/` | INF-05 | DO1 |
| INF-15 | Monitoring stack: kube-prometheus-stack + Loki + Promtail/Alloy + Alertmanager, all **self-hosted in cluster** (no SaaS stores logs) | SRE | `feature/inf-15-monitoring-stack` | `platform/monitoring/` | INF-13, INF-14 | DO2 |
| INF-16 | Cost controls: tagging standard, AWS Budget + alert, `make destroy-staging` script / teardown workflow | SRE | `feature/inf-16-cost-controls` | `envs/*`, `.github/workflows/teardown.yml` | INF-10 | SA |

### Docs check-ins (`merlion-infra/docs`)

| ID | Task | Owner | Branch | Reviewer |
|---|---|---|---|---|
| DOC-01 | Business requirements summary: functional, non-functional, constraints, assumptions | SA | `docs/doc-01-requirements` | SRE |
| DOC-02 | Architecture diagram (app, network, environments, CI/CD, observability), must match what's deployed | SA | `docs/doc-02-architecture` | DO1 |
| DOC-03 | Service selection justification: chosen vs alternative vs why (compute, DB, CI/CD, observability) | SA | `docs/doc-03-service-selection` | DO2 |
| DOC-04 | Constraint compliance mapping: constraint → decision → evidence (file path, policy, screenshot) | SA | `docs/doc-04-compliance-map` | SRE |
| DOC-05 | Monthly prod cost estimate (AWS Pricing Calculator export + table) | SA | `docs/doc-05-cost` | SRE |
| DOC-06 | ADR-001 Runtime (EKS vs ECS) | SA | `docs/adr-001-runtime` | DO1 |
| DOC-07 | ADR-002 CI/CD platform + Singapore self-hosted runners (CI log residency) | DO2 | `docs/adr-002-cicd` | SA |
| DOC-08 | ADR-003 Self-hosted observability vs SaaS (data residency) | SRE | `docs/adr-003-observability` | SA |
| DOC-09 | ADR-004 Audit log immutability (S3 Object Lock compliance mode) | SA | `docs/adr-004-audit-retention` | DO1 |
| DOC-10 | ADR-005 Credentials: GitHub OIDC per environment, no static keys | DO1 | `docs/adr-005-oidc` | DO2 |

---

## 5. `merlion-app` – task breakdown

| ID | Task | Owner | Branch | Key files | Depends on | Reviewer |
|---|---|---|---|---|---|---|
| APP-01 | Create repo, branch protection, CODEOWNERS, PR template, GitHub Environments `staging` and `production` (prod requires reviewers) | DO2 | `feature/app-01-repo-setup` | `.github/*` | – | DO1 |
| APP-02 | Vendor Bank of Anthos source at a pinned release tag into `src/`, recording the upstream commit in README | DO2 | `feature/app-02-import-source` | `src/`, `README.md` | APP-01 | SA |
| APP-03 | Image builds: build each service (frontend, userservice, contacts, balancereader, ledgerwriter, transactionhistory, loadgenerator), tagged with git SHA | DO2 | `feature/app-03-image-builds` | `docker/`, `ci.yml` | APP-02, INF-07 | DO1 |
| APP-04 | **Security gate 1 – SCA:** Trivy `fs` / OWASP dependency-check, fail on **CRITICAL/HIGH** with fix available, no `|| true` | DO2 | `feature/app-04-sca-gate` | `ci.yml` | APP-03 | SRE |
| APP-05 | **Security gate 2 – image scan:** Trivy image, `--exit-code 1 --severity HIGH,CRITICAL`, block push to ECR on failure | DO2 | `feature/app-05-image-gate` | `ci.yml`, `security/.trivyignore` | APP-03 | SRE |
| APP-06 | Secret scanning: gitleaks in CI | DO1 | `feature/app-06-gitleaks` | `ci.yml` | APP-01 | DO2 |
| APP-07 | Helm chart (our own): Deployments/Services per service, resource requests/limits, probes, HPA, PodDisruptionBudgets; DB endpoints pointed at RDS | DO1 | `feature/app-07-helm-chart` | `deploy/helm/` | APP-03, INF-06 | DO2 |
| APP-08 | Secrets delivery: `ExternalSecret` objects pulling DB credentials and JWT keys from AWS Secrets Manager. Nothing in values files or images | DO1 | `feature/app-08-external-secrets` | `deploy/helm/templates/externalsecret.yaml` | APP-07, INF-13 | SRE |
| APP-09 | Env values: `values-staging.yaml` / `values-prod.yaml` (replicas, ingress hosts, resources) | DO1 | `feature/app-09-env-values` | `deploy/helm/values-*.yaml` | APP-07 | SA |
| APP-10 | CD pipeline: on `main` → push to ECR → assume `gh-app-staging` (OIDC) → `helm upgrade` staging → smoke test → **manual approval** → assume `gh-app-prod` → deploy prod | DO2 | `feature/app-10-cd-pipeline` | `cd.yml` | APP-05, APP-09, INF-03 | DO1 |
| APP-11 | Deployment audit record: pipeline writes `{who, PR, commit SHA, image digest, env, time}` to the Object Lock bucket on every prod deploy | SA | `feature/app-11-deploy-audit` | `cd.yml` | APP-10, INF-08 | DO2 |
| APP-12 | Pipeline README: feature → PR → staging → prod flow, how approvals work, **what happens when a security gate fails** | DO2 | `docs/app-12-pipeline-readme` | `README.md` | APP-10 | SA |
| APP-13 | Metrics scraping: ServiceMonitors for app services (Bank of Anthos exposes metrics), ingress-nginx metrics for request rate, errors and latency | SRE | `feature/app-13-servicemonitors` | `deploy/helm/templates/servicemonitor.yaml` | APP-07, INF-15 | DO1 |
| APP-14 | SLIs and SLOs: availability (non-5xx ratio ≥ 99.5%) and p95 latency on transaction history (< 500 ms), justified for a bank enquiry portal, with error budget | SRE | `feature/app-14-slo` | `ops/slo/slo.md` | APP-13 | SA |
| APP-15 | Alerts: ≥2 PrometheusRules tied to SLOs (e.g. error-rate burn, p95 latency breach) + key failure mode (pod CrashLoop / DB unreachable); Alertmanager → email/Telegram. Alert text carries no customer data | SRE | `feature/app-15-alerts` | `ops/alerts/`, `platform/monitoring/` | APP-14 | DO2 |
| APP-16 | Dashboard: "Is the system healthy right now?" – SLO status, request rate, error rate, p95, pod/node CPU and memory, Loki log panel | SRE | `feature/app-16-dashboard` | `ops/dashboards/` | APP-13 | SA |
| APP-17 | Incident runbook: e.g. "ledger-db connection failure" – detection, diagnosis, mitigation, escalation | SRE | `docs/app-17-runbook` | `ops/runbooks/` | APP-15 | DO1 |
| APP-18 | Demo prep: scripted failing-gate PR (vulnerable base image) and alert trigger (scale `ledgerwriter` to 0 or break DB secret in staging) | SRE + DO2 | `feature/app-18-demo-scripts` | `ops/demo/` | APP-05, APP-15 | SA |

---

## 6. Check-in sequence (suggested 4 weeks)

| Week | `merlion-infra` | `merlion-app` | Docs |
|---|---|---|---|
| **1 – Foundations** | INF-01, INF-02, INF-03, INF-04 | APP-01, APP-02 | DOC-01, DOC-06 (runtime ADR first – everything depends on it) |
| **2 – Platform** | INF-05, INF-06, INF-07, INF-08, INF-09, INF-10, INF-11 | APP-03, APP-04, APP-05, APP-06 | DOC-02 draft, DOC-03, DOC-10 |
| **3 – Deploy + observe** | INF-12, INF-13, INF-14, INF-15 | APP-07, APP-08, APP-09, APP-10, APP-11, APP-13 | DOC-07, DOC-08, DOC-09 |
| **4 – Operate + harden** | INF-16 | APP-12, APP-14, APP-15, APP-16, APP-17, APP-18 | DOC-02 final (match deployed), DOC-04, DOC-05, final README |

**Critical path:** INF-02 → INF-03 → INF-04 → INF-05 → INF-13 → APP-07 → APP-10 → (prod running) → APP-13 → APP-15 → live alert demo.

---

## 7. Contribution matrix

Number of PRs each member authors in each repo:

| Member | `merlion-infra` | `merlion-app` | Docs / ADRs | Total |
|---|---|---|---|---|
| SA | 2 (INF-08, INF-09) | 1 (APP-11) | 7 (DOC-01–06, 09) | 10 |
| DO1 | 6 (INF-01–05, INF-10) | 4 (APP-06–09) | 1 (DOC-10) | 11 |
| DO2 | 5 (INF-06, 07, 11, 12, 13) | 7 (APP-01–05, 10, 12) | 1 (DOC-07) | 13 |
| SRE | 3 (INF-14, 15, 16) | 6 (APP-13–18) | 1 (DOC-08) | 10 |

Each member also **reviews** roughly 10 PRs, so review history shows cross-role collaboration too.

---

## 8. Hard-constraint traceability (what to point at in the Q&A)

| Constraint | Check-in that satisfies it | Evidence to show |
|---|---|---|
| **Data residency** – DB, backups, logs in `ap-southeast-1` | INF-06 (RDS in-region, no cross-region copy), INF-09 (region pin + deny), INF-14/15 (Loki on S3 in SG, self-hosted), INF-12 (SG runners) | `terraform state show` region, Loki bucket region, ADR-003, ADR-002 |
| **Auditability** – every prod change traceable | Branch protection (INF-01/APP-01), plan-in-PR (INF-11), prod approval gate (APP-10), deploy audit record (APP-11), CloudTrail (INF-08) | PR → review → Actions run → approver → audit JSON → CloudTrail event |
| **Audit log retention 1 yr, tamper-proof** | INF-08 Object Lock **compliance mode** 365 days, delete denied to engineering roles | Bucket Object Lock config, failed `DeleteObject` attempt, ADR-004 |
| No console changes to prod | INF-03 (prod roles only assumable from the prod GitHub Environment), CloudTrail alerts on console writes | IAM trust policy, CloudTrail query |
| Credential separation | INF-03 per-env OIDC roles, APP-10 assumes a different role per stage | Staging role attempting a prod action → `AccessDenied` |
| Security gates actually block | APP-04, APP-05, INF-11 checkov | Demo PR with failing scan (APP-18) |

---

## 9. Definition of done for every PR

- [ ] Linked to a task ID above
- [ ] Reviewed and approved by someone who isn't the author
- [ ] CI green (fmt/lint/scan/plan or build/scan)
- [ ] No secrets, no hard-coded account IDs or regions outside `ap-southeast-1`
- [ ] Docs, ADRs or diagrams updated if the design changed
- [ ] For infra: `terraform plan` output attached to the PR, and nothing applied manually
