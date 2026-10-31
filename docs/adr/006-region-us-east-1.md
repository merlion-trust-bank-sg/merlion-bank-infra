# ADR-006: Deploy in us-east-1 instead of ap-southeast-1

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Solutions Architect (with instructor approval)
- **Related:** HC-1 Data residency and assumption A-1 (`docs/requirements.md`), ADR-003 (observability), INF-11 (region guardrail), DOC-04 (constraint mapping)

## Context
The Merlion Trust Bank use case (HC-1) requires all customer data, backups and application logs
to remain at rest in `ap-southeast-1` (Singapore). Our instructor has directed the class to deploy
in **`us-east-1`**, where the shared training account and its tooling are set up.

Instructor approval: _add the date and where it was given (for example class session or message)_.

The intent of HC-1 is **data residency**: customer data must not spread across regions or to
third-party SaaS in other jurisdictions. That intent can be met in any single approved region.

## Decision
- Deploy everything in **`us-east-1`**, using two Availability Zones (`us-east-1a`, `us-east-1b`).
- Treat HC-1 as **"all customer data, backups and logs stay in one approved region"**, with
  `us-east-1` as the approved region for this project.
- The region is a **single Terraform variable** (`var.region`) with a validation rule that rejects
  any other value. Changing region is a variable change plus a redeploy.
- CI roles carry a deny-other-regions policy (INF-11), so a mistake in code cannot create
  resources elsewhere.
- No cross-region replication: RDS automated backups and snapshots stay in-region; S3 buckets have
  no cross-region replication; Loki log storage uses an S3 bucket in the same region.
- No SaaS component stores customer data or logs (observability is self-hosted, see ADR-003).
  GitHub stores CI run logs outside the region, so CI output must contain no customer data and
  no application logs.

## Alternatives considered
| Option | Why not chosen |
|---|---|
| Deploy in `ap-southeast-1` as the brief states | Conflicts with the instructor directive and the training account setup |
| Split: data in `ap-southeast-1`, compute in `us-east-1` | Cross-region traffic and latency; data would still be processed outside the residency region; more cost and complexity |

## Consequences
**Positive**
- Matches the training environment; no cross-region workarounds.
- Residency is still enforced: one region, validated in code, denied on CI roles, no replication,
  no SaaS log storage.
- Moving to Singapore later needs `var.region` and the AZ names changed, plus a redeploy.

**Negative / risks**
- Strictly, the brief's literal constraint (Singapore) is not met. Mitigation: this ADR records the
  deviation and approval; the compliance mapping (DOC-04) shows the single-region evidence.
- `us-east-1` is outside Singapore, so a real bank would need its regulator's agreement. This
  applies to the project only because the data is synthetic (A-2).
- AZ names are region-specific and must be updated if the region changes.

## Evidence (to be completed)
- `infra/bootstrap/variables.tf`: `region` defaults to `us-east-1`, with a validation rule
- INF-11: deny-other-regions policy on the CI roles, with an `AccessDenied` from another region
- INF-07 and INF-15: RDS backup configuration and Loki bucket region
