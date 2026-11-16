# ADR-003: Observability – self-hosted Prometheus, Loki, Grafana and Alertmanager on EKS

- **Status:** Accepted
- **Date:** 2026-11-10
- **Deciders:** Site Reliability Engineer, reviewed by Solutions Architect
- **Related:** FR-5, NFR-1, NFR-2, HC-1, HC-2 (`docs/requirements.md`); ADR-001 (EKS); ADR-006 (region); INF-15, INF-16, INF-17, APP-13, APP-14; DOC-05 (cost)

## Context
The brief asks for centralised logging and metrics, a dashboard that answers "is the system
healthy right now?", two SLOs, two live alerts and an incident runbook. Logs and metrics from
all six services must be searchable in one place (FR-5), and the SLOs are 99.9% availability and
p95 latency under 500 ms at the load balancer (NFR-1, NFR-2).

Constraints that shape the choice:
- **HC-1 data residency:** application logs can contain customer data, so they must stay at rest
  in `us-east-1`. No SaaS may store them in another region.
- **HC-2 auditability:** monitoring configuration (dashboards, alert rules, routing) should be
  code, reviewed in PRs like everything else.
- **Runtime:** everything runs on EKS (ADR-001), and Argo CD installs what runs in the cluster
  from `deploy/platform/<env>/` (#19).
- **Team skills:** the course labs used Prometheus, Loki, Grafana and Alertmanager.

## Decision
Run the observability stack **ourselves, on EKS, in `us-east-1`**, in namespace `monitoring`,
installed by **Argo CD** with pinned Helm chart versions:

- **kube-prometheus-stack:** Prometheus (metrics on an encrypted EBS volume), node-exporter,
  kube-state-metrics, Grafana and Alertmanager.
- **Loki** for logs, with chunks in an **S3 bucket in `us-east-1`**, encrypted with our KMS key and
  reached through Pod Identity; compactor retention **365 days**.
- **Grafana Alloy** as the log and metrics collector on every node (Promtail's successor, which
  Grafana has deprecated).
- **YACE** (Yet Another CloudWatch Exporter) with a read-only Pod Identity role, to bring the ALB's
  CloudWatch metrics (`HTTPCode_Target_5XX_Count`, `RequestCount`, `TargetResponseTime`) into
  Prometheus for the SLOs.
- **Alertmanager** routes to email and Telegram (INF-16). Alert text carries metric names and
  thresholds only, never customer data. A **Watchdog** alert proves the alert path itself works.
- Dashboards and alert rules are provisioned from code (JSON dashboards, `PrometheusRule`
  objects), so every change goes through a PR.

## Alternatives considered
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Self-hosted on EKS** | Data stays in `us-east-1`; no per-GB ingest fees; one place for logs, metrics, SLOs and alerts; open-source skills from the labs; config as code | We run, size and upgrade it ourselves; uses node capacity; single replicas can fail silently without a Watchdog | **Chosen** |
| Amazon CloudWatch (Container Insights, Logs, Alarms) | Fully managed, in-region, no extra pods | Per-GB ingest and per-metric fees grow with log volume; weaker query and dashboard experience for SLOs; alert routing to Telegram needs extra glue (SNS → Lambda) | Alternative, not chosen |
| Amazon Managed Service for Prometheus + Amazon Managed Grafana | Managed, in-region, PromQL compatible | Still needs collectors and a log solution; Managed Grafana needs IAM Identity Center or SAML for user sign-in, more setup in a shared training account; per-sample and per-user fees | Not chosen |
| Grafana Cloud | Least to operate | SaaS: logs and metrics stored outside our AWS account and region, which breaks HC-1 | **Rejected** |

## Consequences
**Positive**
- Logs and metrics stay in `us-east-1` (HC-1): Loki chunks in our S3 bucket, Prometheus data on an
  EBS volume in the cluster.
- One Grafana for health, SLOs, error budget and logs per service, readable by non-team viewers.
- Dashboards, rules and routing are reviewed code (HC-2).
- Low running cost: about USD 10 a month in storage and CloudWatch API calls on top of the nodes
  (DOC-05).

**Negative / risks**
- **We operate it.** Single replicas mean a Prometheus or Alertmanager outage would also silence
  alerts. Mitigation: the Watchdog alert, which is expected to fire all the time; if it stops, the
  alert path is broken.
- **Node capacity:** the stack needs roughly one extra `t3.medium` in prod (DOC-05 assumes 4 nodes).
  Mitigation: resource requests and limits; scale the node group if it's short.
- **Nightly cleanup:** staging is rebuilt daily, so staging monitoring history is short-lived. Prod
  history and the Loki bucket need to survive rebuilds.
- **ALB metrics come from CloudWatch** through YACE, so they arrive about a minute late and each
  scrape costs CloudWatch API calls (≈ USD 4 a month, DOC-05).
- **Retention:** Prometheus keeps short-term metrics on its volume (e.g. 15 days); long-term
  evidence is the 365-day logs in Loki and the audit trail (ADR-004).

## Evidence (to be completed in INF-15 to INF-17)
- Argo CD Applications for the stack in `deploy/platform/<env>/`, `Synced` / `Healthy`
- Loki bucket in `us-east-1`, KMS-encrypted, lifecycle and compactor retention 365 days
- Grafana dashboard showing SLO status and logs per service
- A test alert (and the Watchdog) delivered to email and Telegram
