# Constraint Compliance Mapping – Merlion Trust Bank

For each requirement in `docs/requirements.md`: the decision that meets it, where it's implemented,
and the evidence to show an assessor. **Status:** ✅ on `main` · ⏳ in an open PR or not built yet.
**As of 15 Nov 2026**; several rows depend on open PRs (#40, #44, #46, #48) and are updated as they
merge.

Decisions with wider impact have an ADR in `docs/adr/`: 001 runtime (EKS), 002 environments in one
account, 003 observability, 004 audit log immutability, 005 CI credentials (OIDC), 006 region,
007 image promotion.

## 1. Hard constraints

### HC-1 Data residency: customer data, backups and logs at rest in one approved region
Approved region: **`us-east-1`**, per the instructor's direction to the whole class during the
course (ADR-006; the brief names `ap-southeast-1`). The shared training account and its tooling are
set up in `us-east-1` only. The intent, keeping data in one region and out of third-party SaaS, is
met in `us-east-1`.

| Control | Where | Evidence | Status |
|---|---|---|---|
| Terraform refuses any other region | `variable "region"` validation in `bootstrap/` and `envs/{staging,prod}/variables.tf` | `terraform plan -var region=ap-southeast-1` fails: "Data residency: only us-east-1 is approved." | ✅ |
| AWS denies any other region to the pipeline | `DenyOutsideApprovedRegion` on every CI role and workload permissions boundary (`modules/iam-ci/guardrails.tf`) | IAM policy simulator: `ec2:RunInstances` in `ap-southeast-1` as `g4-merlion-ci-staging` → explicit deny | ✅ |
| Databases and backups in-region | RDS in `us-east-1`, automated backups and dated final snapshots in the same region; no cross-region backup replication or copy (`modules/rds`) | `aws rds describe-db-instances` (AZs `us-east-1a/b`), `describe-db-snapshots` | ✅ |
| Application logs in-region, no SaaS | Self-hosted Loki, chunks in S3 `g4-merlion-<env>-loki` (`us-east-1`, KMS); Prometheus on EBS; Grafana in the cluster (ADR-003, `modules/observability`, `deploy/platform/<env>/`) | Loki bucket region; no external log or APM endpoints in `deploy/platform/` | ✅ staging · ⏳ prod (paulyapsl, SRE) |
| Audit logs in-region | Audit bucket `us-east-1`, no cross-region replication (`modules/audit`, `CKV_AWS_144` skip with reason) | `aws s3api get-bucket-location`, no replication configuration | ✅ |
| Images in-region | ECR `merlion/*` in `us-east-1` (`bootstrap/ecr.tf`) | `aws ecr describe-repositories` | ✅ |
| CI output contains no customer data | Assumption A-5: workflows print plans, digests and check results, never app logs or data; synthetic data only (A-2) | Review of `tf-apply` / `cd` run logs | ✅ practice · ⏳ README note (APP-12) |

### HC-2 Auditability: every production change traceable; no direct console changes to prod

**The chain for one prod change:**

| Step | Who / what is recorded | Where | Status |
|---|---|---|---|
| 1. Jira issue | Ticket, owner | SCRUM board; branch `SCRUM-<n>-*`, commit `SCRUM-<n>: …` | ✅ |
| 2. Pull request | Author, diff, required checks | `main` ruleset: PR required, checks `checks`, `plan staging`, promotion checks; **no bypass list** | ✅ |
| 3. Review | An approver other than the author, after the last push | Ruleset: required approval, `require_last_push_approval` | ✅ |
| 4. Pipeline run | Which run changed what, with which role | `tf-apply.yml`: staging applied, then prod planned with the read-only role; AWS session name `ci-<run id>-<attempt>` | ✅ |
| 5. Production approval | Who approved the saved prod plan | GitHub environment `production`: required reviewers, **prevent self-review** | ✅ |
| 6. App deploys | The promotion PR and its approver; image digests signed by our cd and equal to staging's | `promotion.yml` (`pull_request_target`, from `main`), `verify-provenance.py`, ADR-007 | ✅ |
| 7. Deploy record | `{actor, approvers, PR, commit, digests or plan, env, time}` in the Object Lock bucket | `deploy-record.yml`, role `g4-merlion-ci-record` (APP-11) | ⏳ #48 |
| 8. CloudTrail | Every write API call, by role and `ci-<run id>` session | Trail `g4-merlion-trail` (write management events + audit-bucket data events), ADR-004 | ✅ |
| 9. Kubernetes changes | Every API server request (who, verb, object) | EKS audit log in CloudWatch (365 days); copy to the Object Lock bucket via Firehose | ✅ CloudWatch · ⏳ #40 Object Lock copy |

**No direct console changes to prod:**

| Control | Where | Evidence | Status |
|---|---|---|---|
| Only the prod pipeline can change prod | `g4-merlion-ci-prod` trusts only the `production` environment (`modules/iam-ci/trust.tf`); env fence and permissions boundary keep staging's role out of prod | Trust policy; IAM simulator: staging role on a prod resource → deny | ✅ |
| People are read-only in the prod cluster | `admin_principal_arns` = the prod pipeline, plus one named break-glass holder (DevSecOps) for emergency restarts and restores; other people in `viewer_principal_arns` (`envs/prod/eks.tf`). Break-glass actions are in the EKS audit log (Object Lock); restores write a record to `deploys/prod/` (`scripts/restore-iam.sh prod`) | `aws eks list-access-entries`; a viewer's `kubectl` change refused (Forbidden) | ✅ |
| A console change is noticed | EventBridge rule on console write calls by the team's IAM users → SNS email (`modules/console-alert`, INF-11) | One console change and the alert email it produced | ✅ applied; email subscription to confirm |
| Infrastructure only through Terraform | All AWS resources in Terraform; `bootstrap/` applied by an admin, everything else by the pipeline | `terraform plan` shows no drift | ✅ |

### HC-3 Audit log retention: ≥ 1 year, tamper-proof from engineers

| Control | Where | Evidence | Status |
|---|---|---|---|
| Object Lock, governance mode, 365 days | Audit bucket (`modules/audit/bucket.tf`, ADR-004) | `aws s3api get-object-lock-configuration` → `GOVERNANCE`, 365 days | ✅ |
| Nobody can delete or bypass retention | Bucket policy denies `DeleteObject*`, `BypassGovernanceRetention` and Object Lock config changes to everyone | A failed `delete-object` on a CloudTrail log file | ✅ |
| The pipeline can't weaken it | `protect_bootstrap` on every CI role that changes resources and every workload boundary: no bucket config changes, no reads or deletes of audit objects, no trail changes | IAM policy simulator / the guardrail statements | ✅ |
| The key can't be switched off | Audit key policy denies `DisableKey` and `ScheduleKeyDeletion` | Key policy | ✅ |
| Altered log files are detectable | CloudTrail log file validation | `aws cloudtrail validate-logs` | ✅ |
| Pipeline audit outlives GitHub's log expiry | Deploy records in the Object Lock bucket | `aws s3 ls s3://g4-merlion-audit-<account>/deploys/` | ⏳ #48 |
| Kubernetes audit log tamper-proof | Firehose copy under `eks-audit/<cluster>/` | `aws s3 ls …/eks-audit/` and a failed delete | ⏳ #40 |

## 2. Non-functional requirements

| ID | Target | How it's met | Evidence | Status |
|---|---|---|---|---|
| NFR-1 | 99.9% availability | Nodes in 2 AZs; `frontend` HPA 2–4 replicas with a PDB and AZ spread; Multi-AZ RDS and a NAT gateway per AZ in prod | SLO panel and burn-rate alert | ✅ design · ⏳ SLO measurement (APP-14, INF-17) |
| NFR-2 | p95 < 500 ms | ALB `TargetResponseTime` p95 through YACE into Prometheus | SLO panel and latency alert | ✅ metric (staging) · ⏳ SLO and alert |
| NFR-3 | Survive one AZ | 2 AZs; 4 × `t3.medium` (pod capacity left after losing a node, #37); NAT per AZ; Multi-AZ RDS (`envs/prod`) | `describe-db-instances` `MultiAZ: true`, nodes in both AZs | ✅ code · ⏳ prod running (#44) |
| NFR-4 | RPO ≤ 24 h, RTO ≤ 4 h | RDS automated backups (7 days, point-in-time restore), deletion protection and dated final snapshots in prod | Backup config; a timed restore | ✅ backups · ⏳ restore test |
| NFR-5 | Baseline load, `frontend` ≥ 2 with HPA | HPA 2–4 at 70% CPU, metrics-server add-on; load generator in staging only | `kubectl -n bank get hpa frontend` | ✅ |
| NFR-6 | Encryption at rest and in transit; DBs not public | Our own KMS keys for EKS secrets, RDS, Secrets Manager (app secrets), logs, Loki's bucket, state and audit; HTTPS on the ALB (ACM, `ELBSecurityPolicy-TLS13-1-2-2021-06`: TLS 1.2 and 1.3, HTTP → HTTPS redirect); RDS `rds.force_ssl`; isolated DB subnets with no internet route, `publicly_accessible = false`. Exceptions below | Resource configs; `curl -I http://…` redirects to HTTPS | ✅ |
| NFR-7 | Smallest viable cost | DOC-05 estimate; `t3.medium` / `db.t4g.small`; staging smaller than prod (1 NAT, single-AZ RDS, no interface endpoints); prod off by default (`enabled = false`), brought up for testing and the demo; tags for cost allocation; `teardown.yml` removes staging on demand | `docs/cost-estimate.md` | ✅ · ⏳ staging schedule (SRE, below) |

**NFR-6 exceptions: encrypted, but with an AWS-managed key instead of ours**

| What | Key | Why |
|---|---|---|
| Node root volumes, and the Prometheus and Loki volumes (`gp3-encrypted` StorageClass) | `aws/ebs` | Encrypted at rest. A customer-managed key would need key policy grants for the EBS CSI driver and the Auto Scaling service role; the data on them is metrics and log buffers whose long-term copy (Loki in S3) uses our key |
| Alerting secret `g4-merlion-<env>/monitoring/alerting` (#46) | `aws/secretsmanager` | Written once by `put-alert-secret.sh` and kept outside Terraform, so it outlives the environment; the env's own Secrets Manager key is destroyed with the environment |

## 3. General requirements

| Requirement | How it's met | Status |
|---|---|---|
| AWS only, all infrastructure as code | Terraform for everything (`bootstrap/`, `envs/*`, `modules/*`); Kubernetes add-ons and the app via Argo CD from `deploy/` (GitOps) | ✅ |
| Distributed workload, runtime justified | 6 Bank of Anthos services on EKS (ADR-001) | ✅ |
| CI/CD to staging and production, prod approved | `tf-apply.yml` (prod behind the `production` environment); promotion PRs approved by a teammate (ADR-007) | ✅ |
| Security gates with failing thresholds | App: gitleaks, Trivy SCA and image scan (fail on fixable CRITICAL), ECR scan on push. Infra: gitleaks, fmt, validate, tflint, checkov (any failure blocks). Promotion: digests only and signed provenance | ✅ |
| Credential hygiene | GitHub OIDC, one role per kind of job with an exact `sub`, sessions ≤ 1 hour (ADR-005); no static keys; app secrets in Secrets Manager, delivered by External Secrets; the promotion App's key is an Environment secret for `main` only | ✅ |
| Logging, metrics, dashboard | Prometheus, Loki, Alloy, Grafana, YACE on staging (#25); Grafana hostname, login and alert secret (#46, #49); health dashboard (INF-17) | ✅ stack (staging) · ⏳ dashboard, prod |
| 2 SLOs, 2 live alerts | Availability (1 − ALB 5xx ratio, 99.9%) and p95 latency (< 500 ms) (APP-14); alert routing to Telegram (INF-16, #49) and SLO alerts (INF-17) | ⏳ SRE |
| 1 incident runbook | One failure scenario with detection, diagnosis, mitigation and escalation (APP-15). Separate from the rollback runbook (`docs/runbooks/rollback.md`, #45), which covers only the mitigation for a bad release | ⏳ SRE |
| Work tracked in Jira; every PR approved by someone else | `SCRUM-<n>` branches and commits; ruleset requires an approval after the last push | ✅ |

**Deliverables named in the brief (SA and DevSecOps):**

| Deliverable | Where | Status |
|---|---|---|
| Business requirements summary | `docs/requirements.md` (DOC-01) | ✅ |
| Architecture diagram matching what's deployed | `docs/architecture/` (DOC-02) | ⏳ #22 |
| Service selection | `docs/service-selection.md` (DOC-03) | ✅ |
| At least 4 ADRs | `docs/adr/` 001–007 | ✅ 7 ADRs |
| Monthly cost estimate | `docs/cost-estimate.md` (DOC-05) | ✅ |
| Constraint compliance mapping | This document (DOC-04) | ✅ |
| Pipeline README (branch → PR → staging → prod, approvals, what happens when a gate fails, CI-log hygiene) | `README.md` (APP-12, DevSecOps) | ⏳ |

## 4. Known gaps and accepted risks

| Item | Why it's accepted, or what closes it |
|---|---|
| Governance mode, not compliance mode | Instructor advice for a shared training account; the bucket policy denies bypass to everyone, and changing that policy is itself logged (ADR-004) |
| One shared AWS account | No separate accounts in the training environment; isolation by roles, the env fence and permissions boundaries (ADR-002) |
| Read-only API calls not in our trail | Write-only trail by team decision (cost, shared account); reads stay in the account's own trail and the 90-day event history; `include_read_management_events` turns them back on (ADR-004) |
| EKS API endpoint is public | GitHub-hosted runners have no fixed IPs; access is still IAM-authenticated through EKS access entries |
| HIGH vulnerabilities don't block | The application is unmodified upstream code; HIGH findings are reported in CI and by ECR's scan on push (#30) |
| Image signatures checked at promotion, not in the cluster | Nobody but the pipeline can change prod; enforcing signatures in the cluster is future work (ADR-007) |
| Staging schedule | On 15 Nov the nightly teardown's schedule was disabled in GitHub (`gh workflow disable`; the cron is still in `teardown.yml`): a rebuild took about 30 minutes every morning, and the instructor's cleanup now spares our tagged resources. Left running, staging costs about USD 313/month instead of about USD 99 (DOC-05). ⏳ The SRE sets how staging is kept down when idle, and `teardown.yml` is changed to match |
| Prod off by default | Brought up for testing and the demo (#44); evidence for NFR-3 and the prod parts of HC-2 is captured then |

## 5. Evidence checklist for the demo
- [ ] Jira ticket → PR (checks, approval) → `tf-apply` run → `production` approval → deploy record → CloudTrail event with the same `ci-<run id>` session
- [ ] `get-object-lock-configuration` on the audit bucket, and a failed `delete-object`
- [ ] `terraform plan` with another region failing on the region validation
- [ ] A console change by a team member and the alert email it produced
- [ ] A promotion PR failing the promotion check (unsigned digest or an extra change)
- [ ] A PR failing a security gate (APP-16)
- [ ] Multi-AZ RDS and nodes in both AZs (prod)
- [ ] Grafana dashboard with both SLOs, and one alert firing (SRE)
- [ ] Screenshots of settings that aren't in Git: the `main` ruleset (no bypass list, required
      checks, approval after the last push), the `production` environment (required reviewers,
      prevent self-review, `main` only), the `promotion` environment and its App key secret
