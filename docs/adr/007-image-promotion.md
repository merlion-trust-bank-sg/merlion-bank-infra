# ADR-007: Image promotion – build once, promote the same digest through Git

- **Status:** Accepted (staging built; prod promotion to follow)
- **Date:** 2026-11-13
- **Deciders:** DevSecOps, reviewed by Solutions Architect and SRE
- **Related:** FR-4, HC-2 (`docs/requirements.md`); ADR-005 (credentials); APP-10, APP-11; `merlion-bank-app` `cd.yml`; `.github/workflows/promotion.yml`; `deploy/values-<env>.yaml`

## Context
Changes must reach production only through an automated pipeline with an approval step (FR-4),
and every deployment must be traceable (HC-2). The application code is in `merlion-bank-app`; the
Kubernetes configuration and Argo CD's source of truth are in `merlion-bank-infra/deploy/`. We need
to decide how a new image gets from a merge in the app repo to staging, and then to prod.

## Decision
- **Build once.** `cd.yml` in the app repo builds each of the 9 images once per merge to `main`,
  scans it (the same Trivy gate as CI), and pushes it to ECR with the commit SHA as tag. Tags are
  immutable. Environments refer to images **by digest**, so the bytes tested in staging are the
  bytes that run in prod.
- **Git is the deployment record.** Each environment's digests are in
  `merlion-bank-infra/deploy/values-<env>.yaml`. Argo CD deploys whatever is on `main`; a deploy is
  a merged PR, and a rollback is a revert.
- **Staging: automatic.** After pushing, `cd.yml` acts as the **promotion GitHub App** (installed on
  the infra repo only):
  1. updates the digests on branch `promote/staging` (force-pushed from `main`, so one open
     promotion PR at most);
  2. opens or updates the PR, linking the app commit and the cd run;
  3. waits for the required checks, then merges with `--match-head-commit`, so it never merges a
     commit it didn't push.
- **What the App may do, and no more:**
  - **staging promotion only** check: a PR from `promote/staging` or by a bot passes only if its
    single change is `sha256:` digests in `deploy/values-staging.yaml`.
  - Rulesets: the App bypasses the approval rule (pull requests only); the required checks are in a
    separate ruleset with no bypass; only the App may write `promote/**` branches.
  - Its private key is an Environment secret only `main` can read (ADR-005).
- **Prod: same digest, human approval.** A PR copies the digests staging runs into
  `deploy/values-prod.yaml`; it needs an approval from someone other than its author, and the
  merge is the prod deploy. (Next ticket; needs `envs/prod`.)
- **Deploy records** (APP-11): each merged promotion PR is written to the Object Lock audit bucket.

## Alternatives considered
| Option | Why not chosen |
|---|---|
| Push-based CD: the app pipeline runs `helm upgrade` / `kubectl` against the cluster | The app pipeline would need cluster credentials; the cluster's state would drift from Git; no PR per deploy |
| Argo CD Image Updater (watches ECR, writes new tags back to Git) | Needs a Git write key stored in the cluster; promotes on its own schedule rather than in a PR we can gate and audit |
| Separate config repo for `deploy/` | One more repo, access policy and pipeline for 3 people; `merlion-bank-infra` already has the reviews, rulesets and `tf-plan` checks |
| Rebuild the image per environment | What runs in prod would not be what was tested in staging |
| GitHub auto-merge for the staging PR | Merges whatever is on the branch once checks pass, and a stuck promotion leaves no failed run; merging from the workflow with `--match-head-commit` fixes both |
| `GITHUB_TOKEN` instead of an App | Can't open PRs in another repo, and PRs it opens don't trigger workflows, so the required checks would never run |

## Consequences
**Positive**
- One image per commit, scanned once, promoted by digest: staging and prod run identical bytes.
- Every deploy is a PR with an author, checks, a merge commit and (for prod) an approver; Argo CD
  sync history and the deploy record back it up.
- The app repo never has cluster or Terraform credentials; the App can only change digests.
- Rollback is a Git revert; the previous image is still in ECR.

**Negative / risks**
- A GitHub App private key exists. Mitigation: Environment secret for `main` only, App installed on
  one repo, rotation documented, and the App can't skip the checks.
- The digest check validates format, not origin. Mitigation: only the App can write `promote/**`;
  hand-picked digests need a normal reviewed PR.
- A promotion waits on `plan staging`, so it fails if the CI roles are broken (for example after
  the nightly cleanup). The cd run then shows red rather than failing silently.
- Prod promotion is not built yet; until it is, FR-4's approval step is covered only by the
  `production` Environment on `tf-apply`.

## Evidence
- `merlion-bank-app` `cd.yml` (`promote to staging` job) and a merged `Promote merlion-bank-app <sha> to staging` PR.
- `.github/workflows/promotion.yml`, `.github/scripts/check-promotion.py`; ruleset screenshots in app PR #4.
- `deploy/values-staging.yaml` history.
