# ADR-002: Environments – staging and production in one shared account, isolated by IAM

- **Status:** Accepted
- **Date:** 2026-11-13
- **Deciders:** DevSecOps, reviewed by Solutions Architect
- **Related:** HC-2 Auditability, NFR-7 Cost, A-3 (`docs/requirements.md`); ADR-005 (CI credentials); `bootstrap/`, `modules/iam-ci/` (`guardrails.tf`, `boundary.tf`)

## Context
We need a production environment and at least one environment to test changes in first. The usual
way to separate them is one AWS account per environment, so a mistake or a compromised pipeline in
one can't reach the other.

The training account is the only account we have. We can't create accounts or use AWS
Organizations, and other groups work in the same account. Separation therefore has to come from
inside one account.

## Decision
- **Two environments: staging and prod.** Both are built from the same Terraform modules
  (`envs/staging`, `envs/prod`); staging is smaller and runs the load generator.
- **No dev environment.** Branches are checked by `tf-plan` (fmt, validate, tflint, checkov,
  staging plan) and the app's CI; staging is where merged changes run first.
- **Separation inside the account, in four layers:**

| Layer | What it separates | Where |
|---|---|---|
| Terraform state | One state bucket and one KMS key per layer (bootstrap, staging, prod). Each CI role can read and decrypt only its own env's state | `bootstrap/state.tf`, `kms.tf` |
| CI roles | One role per kind of job; the staging and prod deploy roles can only be assumed from the matching GitHub Environment (ADR-005) | `modules/iam-ci/trust.tf` |
| Environment fence | Every deploy role is denied anything tagged with, or named after, the other environment, and can't tag a resource into it | `modules/iam-ci/guardrails.tf` (`env_fence`) |
| Permissions boundary | Every role an env pipeline creates (EKS, nodes, Pod Identity) carries that env's boundary: no IAM changes, no state access, no image pushes, same fence | `modules/iam-ci/boundary.tf` |

- **Other groups' resources:** the deploy roles may not destroy or change resources whose `Team`
  tag isn't ours, and may only tag their own node groups' Auto Scaling groups.
- **Shared by both environments:** the ECR repositories (one image digest is promoted from staging to
  prod, ADR-007), the audit trail and the GitHub OIDC provider. They live in `bootstrap/`, applied
  only by an admin; no pipeline role can change them (`protect_bootstrap`).
- **Prod changes need an approval:** `apply prod` runs in the `production` GitHub Environment,
  which has required reviewers, and applies exactly the plan that was reviewed.

## Alternatives considered
| Option | Why not chosen |
|---|---|
| One account per environment (AWS Organizations) | The strongest isolation and what we'd recommend for a real bank, but not available in the training account |
| Add a dev environment | A third copy of EKS, RDS and NAT costs more than the course budget allows (NFR-7) and adds little over branch plans plus staging |
| One environment, separated by Kubernetes namespaces | Staging and prod would share the cluster, databases and IAM roles; a bad staging change could take prod down |

## Consequences
**Positive**
- A staging pipeline can't read prod state, change prod resources or create roles that can.
- Every control is in code and reviewed in PRs; a broader Allow elsewhere can't override the
  explicit Denies.
- Moving to one account per environment later is mostly a backend and provider change: the
  modules, roles and pipeline stay the same.

**Negative / risks**
- **Weaker than separate accounts.** Account-wide things (service quotas, CloudTrail, the
  account's own admins) are shared, and a mistake in the IAM policies themselves could open a
  path between environments. Mitigation: policies are code, reviewed by DevSecOps; `bootstrap/` is
  applied by an admin only.
- **Tag-based rules depend on tags.** Resources created untagged by AWS services (for example the
  default security group of a VPC) can't be fenced by tag; name-based rules and the boundary
  cover what they can.
- **Shared training account:** other groups have the same rights we do, and the nightly cleanup
  removes some of our resources regardless of tags. That affects availability, not separation.

## Evidence
- `bootstrap/state.tf`, `bootstrap/kms.tf`: one state bucket and key per layer.
- `modules/iam-ci/guardrails.tf`: `env_fence` statements; `modules/iam-ci/boundary.tf`.
- `.github/workflows/tf-apply.yml`: `apply prod` behind the `production` Environment.
