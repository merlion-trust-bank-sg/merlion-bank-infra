# ADR-007: Image promotion – build once, promote the same digest through Git

- **Status:** Accepted (revised 2026-11-15: staging promotions need an approval; images are signed)
- **Date:** 2026-11-13
- **Deciders:** DevSecOps, reviewed by Solutions Architect and SRE
- **Related:** FR-4, HC-2 (`docs/requirements.md`); ADR-005 (credentials); APP-10, APP-11; `merlion-bank-app` `cd.yml`, `.github/scripts/open-promotion-pr.sh`; `.github/workflows/promotion.yml`; `deploy/values-<env>.yaml`

## Context
Changes must reach production only through an automated pipeline with an approval step (FR-4),
and every deployment must be traceable (HC-2). The application code is in `merlion-bank-app`; the
Kubernetes configuration and Argo CD's source of truth are in `merlion-bank-infra/deploy/`. We need
to decide how a new image gets from a merge in the app repo to staging, and then to prod, and how we
know an image being promoted is one our pipeline built.

## Decision
- **Build once.** `cd.yml` in the app repo builds each of the 9 images once per merge to `main`,
  scans it (the same Trivy gate as CI), and pushes it to ECR with the commit SHA as tag. Tags are
  immutable. Environments refer to images **by digest**, so the bytes tested in staging are the
  bytes that run in prod.
- **Sign what we build.** After pushing, cd creates a signed **SLSA build provenance** attestation
  for each digest (`actions/attest`), keyless with the run's OIDC identity and kept in GitHub's
  attestation store. It proves the image was built by `merlion-bank-app/.github/workflows/cd.yml` on
  `refs/heads/main`, from which commit and run; nobody else, account admins included, can produce it.
- **Git is the deployment record.** Each environment's digests are in
  `merlion-bank-infra/deploy/values-<env>.yaml`. Argo CD deploys whatever is on `main`; a deploy is
  a merged PR, and a rollback is a revert.
- **Every promotion is a PR that a teammate approves**, staging included. No pipeline, App or person
  can merge to `main` without an approval: there's no bypass.
- **Staging: opened automatically.** After pushing and signing, cd acts as the **promotion GitHub
  App** (installed on the infra repo only):
  1. sets the digests on branch `promote/staging` (force-pushed from `main`, so one open promotion PR
     at most; a newer app merge updates it);
  2. opens or updates the PR, listing every app change it adds since the version staging runs now
     (found from that version's provenance), with links to the commits and the cd run;
  3. stops. A teammate approves and merges.

  The App is needed only because PRs opened with a workflow's `GITHUB_TOKEN` don't trigger the
  required checks. It can push `promote/**` branches and open PRs; it never merges.
- **Prod: the same digests, also approved.** A promotion PR copies the digests staging runs into
  `deploy/values-prod.yaml`; merging it is the prod deploy.
- **What a promotion PR may contain** (required checks, `promotion.yml`, run from `main` with
  `pull_request_target` so a PR can't change the check it's judged by):
  - **staging promotion only:** a PR from `promote/staging` or by a bot changes nothing but `sha256:`
    digests in `deploy/values-staging.yaml`;
  - **every digest it sets is signed by cd on `main`** (its provenance is verified);
  - **prod promotion only:** a PR from `promote/prod` changes nothing but digests in
    `deploy/values-prod.yaml`, each equal to the digest staging runs on `main` and signed by cd.

  So a reviewer only decides *whether* to deploy this version; the checks guarantee *what* it is.
- **Deploy records** (APP-11): each merged promotion and each apply is written to the Object Lock
  audit bucket.

## Alternatives considered
| Option | Why not chosen |
|---|---|
| Push-based CD: the app pipeline runs `helm upgrade` / `kubectl` against the cluster | The app pipeline would need cluster credentials; the cluster's state would drift from Git; no PR per deploy |
| Argo CD Image Updater (watches ECR, writes new tags back to Git) | Needs a Git write key stored in the cluster; promotes on its own schedule rather than in a PR we can gate and audit |
| Separate config repo for `deploy/` | One more repo, access policy and pipeline for 3 people; `merlion-bank-infra` already has the reviews, rulesets and `tf-plan` checks |
| Rebuild the image per environment | What runs in prod would not be what was tested in staging |
| **Staging promoted automatically** (the App merges its own PR once checks pass, with a ruleset bypass of the approval) | Our first design. A ruleset bypass can't be limited by branch, so it applied to every PR the App opens, prod included; it needed split rulesets and branch restrictions to contain it, and the check was then the App's only limit. Approving staging promotions removes the bypass entirely, at the cost of a review per release, which also matches change control in a bank |
| A separate prod registry, images copied there on promotion | Strong where each environment has its own account; in our one account an admin reaches both registries anyway. Signed provenance gives the "prod only runs what our pipeline built" guarantee without a second registry |
| Commit-tag check (a digest must carry a commit-SHA tag in ECR) | An admin can push an image with any tag. Signatures can't be forged that way, and need no AWS access in the check |
| `GITHUB_TOKEN` instead of an App | Can't open PRs in another repo, and PRs it opens don't trigger workflows, so the required checks would never run |

## Consequences
**Positive**
- One image per commit, scanned once, signed, promoted by digest: staging and prod run identical
  bytes, and each one is provably from our pipeline.
- Every deploy, in every environment, is a PR with an author, checks, an approver and a merge commit;
  Argo CD sync history and the deploy record back it up.
- One ruleset, no bypass list: the same rule for people, pipelines and the App.
- The app repo never has cluster or Terraform credentials; the App can only open PRs.
- Rollback is a Git revert; the previous image is still in ECR.

**Negative / risks**
- **Staging isn't continuous deployment:** a release reaches staging when a teammate approves the
  promotion, not minutes after merge. Mitigation: one open promotion PR at most, always the newest.
- **Signatures are checked at promotion, not in the cluster.** Someone with cluster access could run
  an unsigned image directly. In prod nobody but the pipeline has write access to the cluster; in
  staging, Argo CD's self-heal reverts it within minutes. Enforcing signatures in the cluster
  (Kyverno / Sigstore policy controller) is future work.
- A GitHub App private key exists. Mitigation: Environment secret for `main` only, App installed on
  one repo, rotation documented, and the App can't merge.
- Images built before signing was added have no provenance; promotions only verify the digests they
  set, so they don't block, but those images can't be promoted to prod.
- A promotion waits on `plan staging`, so it can't be approved while the CI roles are broken (for
  example after the nightly cleanup).

## Evidence
- `merlion-bank-app` `cd.yml` (`promote to staging` job, attestations) and a merged
  `Promote merlion-bank-app <sha> to staging` PR with its approval.
- `gh attestation verify` on a promoted digest (app README, "Image provenance").
- `.github/workflows/promotion.yml`, `.github/scripts/check-promotion.py`; a promotion PR failing the
  check (unsigned digest, or a change outside the digests); the ruleset screenshot (no bypass list).
- `deploy/values-staging.yaml` and `deploy/values-prod.yaml` history.
