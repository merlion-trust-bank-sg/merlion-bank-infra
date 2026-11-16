# Cost Estimate – Merlion Trust Bank

Monthly cost in `us-east-1`, on-demand prices from the AWS Price List API (queried 10 Nov 2026),
730 hours per month, no free tier, no Savings Plans. Taxes excluded. Figures are estimates; the
usage assumptions are listed so they can be checked against real usage. AWS Budgets and Cost
Explorer aren't available in the training account (README, Cost controls).

## Summary
| Scope | Monthly (USD) | Notes |
|---|---:|---|
| **Production** (when on) | **≈ 513** | Table 1. Off by default (`enabled = false` in `envs/prod`): USD 0 while torn down |
| **Shared** (state, audit trail, ECR) | **≈ 10** | Table 2, trail records write events only (ADR-004) |
| **Staging** (≈ 220 h/month) | **≈ 99** | Table 3; ≈ 313 if left on 24/7 |
| **Total** | **≈ 622** | ≈ 109 while prod is off |

## 1. Production
| Item | Sizing / assumption | Unit price | Monthly |
|---|---|---|---:|
| EKS control plane | 1 cluster, standard support | $0.10 / h | 73.00 |
| Worker nodes | 4 × `t3.medium` (6 services, `frontend` ≥ 2 replicas, Argo CD, LB Controller, External Secrets, monitoring stack) | $0.0416 / h each | 121.47 |
| Node root volumes | 4 × 30 GB gp3 | $0.08 / GB-mo | 9.60 |
| Prometheus volume | 20 GiB gp3 (EBS PV, 15-day retention) | $0.08 / GB-mo | 1.60 |
| Loki volume | 10 GiB gp3 (single binary; chunks themselves are in S3) | $0.08 / GB-mo | 0.80 |
| RDS instances | 2 × `db.t4g.small` PostgreSQL, **Multi-AZ** | $0.065 / h each | 94.90 |
| RDS storage | 2 × 20 GB gp3, Multi-AZ | $0.23 / GB-mo | 9.20 |
| RDS backups | 7 days, within the free allowance (≤ DB size) | – | 0.00 |
| NAT gateways | 2 (one per AZ) | $0.045 / h each | 65.70 |
| NAT data | ≈ 30 GB (image layers not covered by the S3 gateway endpoint, updates) | $0.045 / GB | 1.35 |
| Interface endpoints | 5 (ECR API, ECR Docker, Secrets Manager, Logs, STS) × 2 AZs; data ≈ 30 GB | $0.01 / h per AZ + $0.01 / GB | 73.30 |
| Public IPv4 | 2 NAT + 2 ALB addresses | $0.005 / h each | 14.60 |
| Application Load Balancer | 1 ALB, ≈ 1 LCU on average | $0.0225 / h + $0.008 / LCU-h | 22.27 |
| KMS keys | 5: logs, EKS secrets, RDS storage, Secrets Manager (incl. the RDS master passwords), Loki | $1 / key-mo | 5.00 |
| Secrets Manager | 5 secrets (2 RDS, JWT key pair, Grafana admin, alert credentials) | $0.40 / secret-mo | 2.00 |
| CloudWatch Logs ingestion | EKS control-plane logs ≈ 10 GB, VPC flow logs ≈ 5 GB | $0.50 / GB | 7.50 |
| CloudWatch Logs storage | 365-day retention; ≈ 180 GB after a year | $0.03 / GB-mo | 5.40 |
| Loki chunks (S3) | ≈ 60 GB after a year (365-day retention) | $0.023 / GB-mo | 1.38 |
| YACE (CloudWatch API) | ≈ 10 ALB metrics every 60 s ≈ 440,000 metrics | $0.01 / 1,000 metrics | 4.38 |
| **Total** | | | **≈ 513** |

## 2. Shared (bootstrap layer, one per account)
| Item | Sizing / assumption | Unit price | Monthly |
|---|---|---|---:|
| KMS keys | 3 state keys + 1 audit key | $1 / key-mo | 4.00 |
| CloudTrail, write management events | ≈ 60,000–200,000 events (see below) | $2 / 100,000 | 1.20–4.00 |
| CloudTrail, audit-bucket data events | a few thousand | $0.10 / 100,000 | < 0.01 |
| Audit bucket (S3) | ≈ 10 GB after a year, kept indefinitely | $0.023 / GB-mo | 0.23 |
| State buckets (S3) | < 1 GB | $0.023 / GB-mo | 0.02 |
| ECR | 9 repositories, last 30 images each, ≈ 15 GB | $0.10 / GB-mo | 1.50 |
| **Total** | | | **≈ 7–11** |

**CloudTrail read events.** The trail records write management events only (ADR-004,
`include_read_management_events = false` in `modules/audit`). The account is shared with other
groups, and the trail records every group's events, not only ours. These two 10-minute samples of
management events in `us-east-1` are the reason:

| Sample | Read | Write | of which KMS | of which Secrets Manager |
|---|---:|---:|---:|---:|
| Mon 10 Nov, evening | 376 | 14 | – | – |
| Thu 12 Nov, 21:51 | 2,739 | 43 | 423 | 7 |

That is ≈ 1.6–12 million read events a month (before daytime peaks and other regions) against
≈ 60,000–190,000 writes. Our trail is an additional copy at $2 per 100,000 events:

| Option | Read events recorded | Cost / month | What's lost |
|---|---|---:|---|
| Read and write | all | ≈ 35–240 | nothing |
| Read and write, KMS excluded | all except `kms.amazonaws.com` | ≈ 30–205 | who decrypted with which key |
| Write, plus Secrets Manager reads | `secretsmanager.amazonaws.com` only | ≈ 1–4 | other services' reads (`Describe*`, `List*`, `Get*`) |
| **Write only (chosen)** | none | **≈ 1–4** | read events, incl. `GetSecretValue` and `AssumeRoleWithWebIdentity` |

**Decision (team, #20):** write events only. HC-2 is about who changed what, and every write by a CI
role carries its `ci-<run id>-<attempt>` session name. Excluding KMS alone only removed about 15% of
the reads in the busier sample. Read events stay in the account's own trail and the 90-day event
history; ADR-004 lists this as a risk, and `include_read_management_events = true` turns them back
on (cost as in the first row).

## 3. Staging
Same modules, smaller: 4 × `t3.medium` (as prod, for pod capacity), 2 × `db.t4g.small`
**single-AZ**, 1 NAT gateway, no interface endpoints. Staging is rebuilt by the pipeline and removed
every night, so it runs about 10 hours a day on working days (≈ 220 hours a month).

| Item | Per hour | ≈ 220 h | 24/7 (730 h) |
|---|---:|---:|---:|
| EKS control plane | 0.100 | 22.00 | 73.00 |
| 4 × `t3.medium` | 0.166 | 36.61 | 121.47 |
| 2 × `db.t4g.small` single-AZ | 0.064 | 14.08 | 46.72 |
| 1 NAT gateway | 0.045 | 9.90 | 32.85 |
| 3 public IPv4 (NAT + ALB) | 0.015 | 3.30 | 10.95 |
| ALB (≈ 1 LCU) | 0.031 | 6.71 | 22.27 |
| Storage, logs, keys, secrets | – | ≈ 6.00 | ≈ 6.00 |
| **Total** | **≈ 0.42** | **≈ 99** | **≈ 313** |

## 4. Cost levers (NFR-7)
| Lever | Saving | Trade-off |
|---|---:|---|
| Prod off by default (`enabled = false`), **in use** | ≈ 513 / month while off | Bringing prod up is a reviewed PR plus a production approval |
| CloudTrail write events only, **in use** | ≈ 35–235 / month | Read events only in the account's trail (ADR-004) |
| Staging torn down nightly (INF-18), **in use** | ≈ 214 / month vs 24/7 | Start-up time before testing |
| No interface endpoints in prod | ≈ 73 / month | ECR, STS, Secrets Manager and Logs traffic goes through NAT (paid per GB) and leaves the VPC |
| One NAT gateway in prod | ≈ 37 / month (gateway + its IPv4 address) | An AZ outage cuts egress for the other AZ (NFR-3) |
| Compute Savings Plan (1 year, no upfront) | roughly 20–30% of node cost | Commitment beyond the project |
| `t4g.large` (ARM) nodes | better price per vCPU | Needs arm64 images for every service |

Not included: data transfer to the internet (small for a synthetic workload), Grafana SSO, and AWS
Support plans. Route 53 and ACM add nothing: the hostname is a record in the course's shared zone,
alias queries to the ALB are free, and public ACM certificates are free.
