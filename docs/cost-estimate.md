# Cost Estimate – Merlion Trust Bank

Monthly cost in `us-east-1`, on-demand prices from the AWS Price List API (queried 10 Nov 2026),
730 hours per month, no free tier, no Savings Plans. Taxes excluded. Figures are estimates; the
usage assumptions are listed so they can be checked against real bills (INF-18 Budgets alert).

## Summary
| Scope | Monthly (USD) | Notes |
|---|---:|---|
| **Production** (always on) | **≈ 443** | Table 1 |
| **Shared** (state, audit trail, ECR) | **≈ 10** | Table 2, with write-only management events (recommended) |
| **Staging** (≈ 220 h/month) | **≈ 90** | Table 3; ≈ 283 if left on 24/7 |
| **Total** | **≈ 543** | ≈ 580–640 if the trail also records read events |

## 1. Production
| Item | Sizing / assumption | Unit price | Monthly |
|---|---|---|---:|
| EKS control plane | 1 cluster, standard support | $0.10 / h | 73.00 |
| Worker nodes | 4 × `t3.medium` (6 services, `frontend` ≥ 2 replicas, Argo CD, LB Controller, External Secrets, monitoring stack) | $0.0416 / h each | 121.47 |
| Node root volumes | 4 × 30 GB gp3 | $0.08 / GB-mo | 9.60 |
| Prometheus volume | 50 GB gp3 (EBS PV) | $0.08 / GB-mo | 4.00 |
| RDS instances | 2 × `db.t4g.small` PostgreSQL, **Multi-AZ** | $0.065 / h each | 94.90 |
| RDS storage | 2 × 20 GB gp3, Multi-AZ | $0.23 / GB-mo | 9.20 |
| RDS backups | 7 days, within the free allowance (≤ DB size) | – | 0.00 |
| NAT gateways | 2 (one per AZ) | $0.045 / h each | 65.70 |
| NAT data | ≈ 30 GB (image layers not covered by the S3 gateway endpoint, updates) | $0.045 / GB | 1.35 |
| Public IPv4 | 2 NAT + 2 ALB addresses | $0.005 / h each | 14.60 |
| Application Load Balancer | 1 ALB, ≈ 1 LCU on average | $0.0225 / h + $0.008 / LCU-h | 22.27 |
| KMS keys | 5 (logs, EKS secrets, RDS, Secrets Manager, Loki) | $1 / key-mo | 5.00 |
| Secrets Manager | 5 secrets (2 RDS, JWT key pair, Grafana admin, alert credentials) | $0.40 / secret-mo | 2.00 |
| CloudWatch Logs ingestion | EKS control-plane logs ≈ 10 GB, VPC flow logs ≈ 5 GB | $0.50 / GB | 7.50 |
| CloudWatch Logs storage | 365-day retention; ≈ 180 GB after a year | $0.03 / GB-mo | 5.40 |
| Loki chunks (S3) | ≈ 60 GB after a year (365-day retention) | $0.023 / GB-mo | 1.38 |
| YACE (CloudWatch API) | ≈ 10 ALB metrics every 60 s ≈ 440,000 metrics | $0.01 / 1,000 metrics | 4.38 |
| **Total** | | | **≈ 443** |

## 2. Shared (bootstrap layer, one per account)
| Item | Sizing / assumption | Unit price | Monthly |
|---|---|---|---:|
| KMS keys | 3 state keys + 1 audit key | $1 / key-mo | 4.00 |
| CloudTrail, write management events | ≈ 60,000–200,000 events (see below) | $2 / 100,000 | 1.20–4.00 |
| CloudTrail, audit-bucket data events | a few thousand | $0.10 / 100,000 | < 0.01 |
| Audit bucket (S3) | ≈ 10 GB after a year, kept indefinitely | $0.023 / GB-mo | 0.23 |
| State buckets (S3) | < 1 GB | $0.023 / GB-mo | 0.02 |
| ECR | 7 repositories, last 20 images each, ≈ 10 GB | $0.10 / GB-mo | 1.00 |
| **Total** | | | **≈ 7–10** |

**CloudTrail read events.** ADR-004 records read and write management events. The account is
shared with other groups, and the trail records every group's events, not only ours. A
10-minute sample on a weekday evening showed **376 read** and **14 write** management events in
`us-east-1`, which is ≈ 1.6 million reads and ≈ 60,000 writes per month before daytime peaks and
other regions. Our trail is an additional copy, so reads would cost **≈ USD 35–100 a month**,
more than the rest of the shared layer and most production line items.

**Recommendation:** record **write** management events only (`include_read_management_events = false`
in `modules/audit`), plus the existing data events on the audit bucket. HC-2 is about changes, and
writes include every `AssumeRoleWithWebIdentity` by the CI roles. ADR-004 to be updated to match.

## 3. Staging
Same modules, smaller: 3 × `t3.medium`, 2 × `db.t4g.small` **single-AZ**, 1 NAT gateway. Staging is
rebuilt by the pipeline and removed every night, so it runs about 10 hours a day on working days
(≈ 220 hours a month).

| Item | Per hour | ≈ 220 h | 24/7 (730 h) |
|---|---:|---:|---:|
| EKS control plane | 0.100 | 22.00 | 73.00 |
| 3 × `t3.medium` | 0.125 | 27.46 | 91.10 |
| 2 × `db.t4g.small` single-AZ | 0.064 | 14.08 | 46.72 |
| 1 NAT gateway | 0.045 | 9.90 | 32.85 |
| 3 public IPv4 (NAT + ALB) | 0.015 | 3.30 | 10.95 |
| ALB (≈ 1 LCU) | 0.031 | 6.71 | 22.27 |
| Storage, logs, keys, secrets | – | ≈ 6.00 | ≈ 6.00 |
| **Total** | **≈ 0.38** | **≈ 90** | **≈ 283** |

## 4. Cost levers (NFR-7)
| Lever | Saving | Trade-off |
|---|---:|---|
| CloudTrail write-only management events | ≈ 35–100 / month | Read calls not recorded (changes still are) |
| Staging scale-to-zero when idle (INF-18) | ≈ 190 / month vs 24/7 | Start-up time before testing |
| One NAT gateway in prod | ≈ 37 / month (gateway + its IPv4 address) | An AZ outage cuts egress for the other AZ (NFR-3) |
| Compute Savings Plan (1 year, no upfront) | roughly 20–30% of node cost | Commitment beyond the project |
| `t4g.large` (ARM) nodes | better price per vCPU | Needs arm64 images for every service |

Not included: data transfer to the internet (small for a synthetic workload), Route 53 (no
custom domain yet), Grafana SSO, and AWS Support plans.
