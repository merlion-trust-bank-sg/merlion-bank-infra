# Business Requirements – Merlion Trust Bank

## 1. Business summary
Merlion Trust is a licensed digital bank launching a customer-facing **transaction enquiry portal**.
As a regulated financial institution it must show that every production change is controlled and
traceable, that customer data stays in one approved region, and that audit evidence cannot be
altered by the engineering team.

We deploy **Google Bank of Anthos** (synthetic data) as the reference workload. Application
features are not in scope; the platform around it is.

## 2. Functional requirements
| ID | Requirement |
|---|---|
| FR-1 | Customers can sign in, view balance and transaction history, and make transfers / deposits through a web frontend over HTTPS |
| FR-2 | Six independently deployable services: `frontend`, `userservice`, `contacts`, `ledgerwriter`, `balancereader`, `transactionhistory` |
| FR-3 | Persistent data in two PostgreSQL databases: `accounts-db` and `ledger-db` |
| FR-4 | Changes reach production only through an automated pipeline with an approval step |
| FR-5 | Logs and metrics from all services are searchable in one place, with a health dashboard readable by non-team viewers |

## 3. Non-functional requirements
| ID | Category | Target | Rationale |
|---|---|---|---|
| NFR-1 | Availability | **99.9%** monthly for the customer path (≈ 43 min downtime / month) | Customer-facing banking portal |
| NFR-2 | Latency | **p95 < 500 ms** at the load balancer | Enquiry pages must feel instant |
| NFR-3 | Resilience | Survive loss of one Availability Zone (2 AZs; Multi-AZ RDS in prod) | No single-AZ failure takes the portal down |
| NFR-4 | Recovery | RPO ≤ 24 h, RTO ≤ 4 h (automated RDS backups) | Assumed bank standard for an enquiry portal |
| NFR-5 | Scale | Baseline load from the Bank of Anthos load generator; `frontend` ≥ 2 replicas with HPA | Synthetic traffic only |
| NFR-6 | Security | Encryption at rest (KMS) and in transit (TLS); databases not publicly reachable | Regulated data |
| NFR-7 | Cost | Smallest viable sizes; staging scaled down when idle; teardown after demos | Project budget |

## 4. Hard constraints (Use Case A)
| ID | Constraint | Our interpretation |
|---|---|---|
| HC-1 | **Data residency**: customer data, backups and application logs at rest in one approved region | Brief names `ap-southeast-1`; instructor directive is **`us-east-1`** (see ADR-006). No SaaS tool may store customer data or logs outside that region |
| HC-2 | **Auditability**: every production change traceable (who, what, when, which pipeline); no direct console changes to prod | Jira issue + PR + reviewer + pipeline run + approval + CloudTrail + deploy record |
| HC-3 | **Audit log retention**: pipeline and infrastructure audit logs kept ≥ 1 year, tamper-proof from engineers | S3 Object Lock (governance mode, bypass denied), 365 days (see ADR-004) |

## 5. General requirements
- AWS only; **all infrastructure as code (Terraform)**, no click-ops
- Distributed, multi-service containerised workload; runtime choice justified in an ADR
- CI/CD to 2 environments (staging, production), production gated by approval
- Security gates in CI: dependency (SCA) and container image scanning with failing thresholds
- Credential hygiene: per-environment roles, short-lived credentials (GitHub OIDC), no secrets in code
- Centralised logging, metrics, dashboard, 2 SLOs, 2 live alerts, 1 incident runbook
- Team of four (SA, two DevSecOps, SRE); work tracked on the Jira SCRUM board, and every PR is approved by someone other than its author

## 6. Assumptions
| ID | Assumption |
|---|---|
| A-1 | Region `us-east-1` replaces `ap-southeast-1` per instructor; region is one Terraform variable |
| A-2 | Synthetic / sample data only; no real customer data |
| A-3 | The platform runs in one AWS training account shared with other groups. Resources carry our group prefix `g4-`; staging and production are separated by `Environment` tag, Terraform state key and per-environment CI role (ADR-002) |
| A-4 | Bank of Anthos source is used unmodified apart from configuration needed to reach RDS |
| A-5 | GitHub-hosted runners are used; CI output contains no customer data or application logs |

## 7. Out of scope
- New banking features or UI changes
- Real payment rails, KYC or identity providers
- Multi-region disaster recovery
