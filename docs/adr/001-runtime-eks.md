# ADR-001: Container runtime – Amazon EKS

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Solutions Architect, reviewed by DevSecOps (DO1)
- **Related:** FR-2, NFR-1, NFR-3, HC-1, HC-2 (`docs/requirements.md`); ADR-003 (observability)

## Context
Bank of Anthos is a distributed workload: 6 services that must be independently deployable,
with service-to-service calls, JWT authentication, health probes and horizontal scaling.
The brief requires us to choose and justify the runtime; Kubernetes is not mandatory.

Constraints that shape the choice:
- **HC-1 data residency:** logs and metrics must stay in-region with no SaaS. We plan to run the
  observability stack (Prometheus, Loki, Grafana) ourselves, inside the platform.
- **HC-2 auditability:** every change must flow through a pipeline; the deployment definition must
  be code that is reviewed in a PR.
- **NFR-1/3:** 99.9% availability, survive the loss of one AZ.
- Team skills: the team of four has lab experience with Kubernetes, Helm, Prometheus, Loki and Grafana.

## Decision
Use **Amazon EKS** (managed Kubernetes control plane) with a **managed node group** in private
subnets across 2 AZs, deploying the application with **our own Helm chart**.

## Alternatives considered
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Amazon ECS on Fargate** | No nodes to manage; cheaper at small scale; simpler IAM per task | Bank of Anthos ships Kubernetes manifests only, so we would rewrite 6 services as task definitions; self-hosted Prometheus/Loki/Grafana is awkward on Fargate (no DaemonSets, no node-level log collection); team has less ECS experience | Rejected |
| **Amazon ECS on EC2** | Lower cost than EKS control plane | Same rewrite effort; we manage instances; weaker ecosystem for our observability stack | Rejected |
| **Amazon EKS** | Runs Bank of Anthos close to upstream design; DaemonSets for Promtail/node-exporter; Helm for repeatable deploys; HPA, PDBs, probes; IRSA for per-pod AWS permissions; matches team skills | Control plane fee (~USD 73/month per cluster); more moving parts; Kubernetes upgrades to manage | **Chosen** |

## Consequences
**Positive**
- Self-hosted observability (ADR-003) runs naturally on the same cluster, keeping logs in-region (HC-1).
- Helm values per environment give one reviewed, versioned deployment definition (HC-2).
- PDBs, multi-replica `frontend`, and nodes across 2 AZs support NFR-1/NFR-3.
- IRSA gives each workload least-privilege AWS access (e.g. External Secrets, Loki → S3).

**Negative / risks**
- Higher fixed cost: the EKS control plane plus nodes. Mitigation: small node group, scale staging to 0
  when idle, tear down after demos (INF-18).
- Operational complexity (add-ons, upgrades). Mitigation: managed node groups, pinned Helm chart
  versions, everything in Terraform.
- Cluster access must be controlled: EKS access entries map only pipeline roles and named admins.

## Evidence (to be completed when built)
- `modules/eks/` (INF-06): cluster, node group, IRSA
- `kubectl get nodes` showing nodes in `us-east-1a` and `us-east-1b`
