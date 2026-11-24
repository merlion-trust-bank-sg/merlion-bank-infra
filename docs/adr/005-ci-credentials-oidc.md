# ADR-005: Pipeline credentials – GitHub OIDC, one role per kind of job, exact subject

- **Status:** Accepted
- **Date:** 2026-11-13
- **Deciders:** DevSecOps, reviewed by Solutions Architect
- **Related:** HC-2 Auditability, FR-4 (`docs/requirements.md`); ADR-002 (environments), ADR-007 (promotion); `bootstrap/oidc.tf`, `modules/iam-ci/trust.tf`

## Context
The pipelines need AWS access: to push images, plan, and apply each environment. Long-lived IAM
user access keys stored as GitHub secrets are the common shortcut, but they never expire, work from
anywhere, and anyone who can run a workflow can read them. A leaked key would give full pipeline
access until someone noticed.

## Decision
- **No static AWS keys anywhere.** Workflows exchange GitHub's OIDC token for short-lived
  credentials (`sts:AssumeRoleWithWebIdentity`, at most 1 hour).
- **One role per kind of job**, each with only what that job needs:

| Role | Assumed by | May |
|---|---|---|
| `g4-merlion-ci-build` | app repo, push to `main` | push images to `merlion/*` in ECR |
| `g4-merlion-ci-plan` | infra repo, pull requests | read-only plan of staging (lock file only) |
| `g4-merlion-ci-prod-plan` | infra repo, `main`, no environment | read-only plan of prod |
| `g4-merlion-ci-staging` | infra repo, `staging` Environment | change staging only |
| `g4-merlion-ci-prod` | infra repo, `production` Environment (after a reviewer approves) | change prod only |
| `g4-merlion-ci-record` | infra repo, `main`, no environment | add deploy records to the audit bucket (APP-11) |
| `g4-merlion-ci-restore` | infra repo, `main`, no environment | re-attach the CI roles' own policies after the nightly cleanup, from a fixed list in its own policy |

- **Exact subject, no wildcards.** Each trust policy matches the token's `sub` claim exactly, in
  GitHub's immutable format `repo:<org>@<org id>/<repo>@<repo id>:<context>`. The numeric IDs mean a
  deleted and re-created repo or org with the same name can't assume our roles. `aud` must be
  `sts.amazonaws.com`.
- **The context is part of the subject:** a PR gets `pull_request`, a push to main gets
  `ref:refs/heads/main`, a job in a GitHub Environment gets `environment:<name>`. So a branch can
  never assume the build or deploy roles, and only a job that passed the `production` approval can
  assume the prod role.
- **Guardrails on top:** deploy roles carry explicit Denies (bootstrap, audit trail, other
  environment, other teams, other regions) and every role they create carries a permissions
  boundary (ADR-002).
- **Traceability:** each workflow sets the role session name to `ci-<run id>-<attempt>`, so every
  AWS call in CloudTrail links back to its GitHub Actions run.
- **The OIDC provider is read, not created:** the account allows one provider per URL and other
  groups use it, so `bootstrap/oidc.tf` looks it up instead of owning it.
- **The one non-AWS secret:** the promotion GitHub App's private key (ADR-007) can't use OIDC. It is
  an Environment secret that only `main` can read, with a documented rotation (app repo README).

## Alternatives considered
| Option | Why not chosen |
|---|---|
| IAM user access keys in GitHub secrets | Never expire, usable from anywhere, readable by any workflow; rotation is manual |
| One shared CI role with wildcard subject (`repo:org/*`) | Any branch or repo in the org could deploy prod |
| Self-hosted runners with an instance role | Runners to patch and secure, and the role would be shared by every job on the runner |

## Consequences
**Positive**
- Nothing to leak or rotate for AWS; credentials expire within the hour.
- Each job's blast radius is limited to its role; the prod role requires the approval.
- CloudTrail session names give the "which pipeline run" part of HC-2.

**Negative / risks**
- Trust policies depend on GitHub's `sub` format and our repo IDs; a renamed claim format or a
  re-created repo needs `bootstrap/` updated. Mitigation: IDs are variables in
  `bootstrap/variables.tf`.
- Whoever administers the GitHub Environments (reviewers, branch rules) effectively controls who
  can deploy prod. Mitigation: org admins only; changes appear in the GitHub audit log.
- The nightly cleanup in the training account detaches every role's policies, the CI roles'
  included, so CI fails each morning until they're back. Mitigation: the `restore` workflow
  (`g4-merlion-ci-restore`) re-attaches them and repairs the environments through the normal
  roles and approvals. It needs one manual step first: an admin re-attaches the restore role's own
  policy, because a role with no permissions can't give itself any. The restore role can only
  attach the policies listed in its own policy, so the CI roles' policies are all managed (the
  cleanup keeps those) and it never writes policy content.

## Evidence
- `modules/iam-ci/trust.tf`: subjects per role.
- A failed `AssumeRoleWithWebIdentity` from a branch, and a successful one from `main`, in the
  Actions logs.
- CloudTrail events with `ci-<run id>` session names.
