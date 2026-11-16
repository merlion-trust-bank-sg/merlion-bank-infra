# Runbook: roll back a deployment (staging or prod)

**When:** a release promoted to an environment (a merged `promote/staging` or `promote/prod` PR) has a
bug, and the environment should go back to the version it ran before.

**Principle:** Git is the deployment record ([ADR-007](../adr/007-image-promotion.md)). Argo CD deploys
whatever `deploy/values-<env>.yaml` says on `main`, so a rollback is a **revert of the promotion PR**,
reviewed and merged like any change. Nobody changes the cluster by hand (HC-2).

## Steps

1. **Find the promotion that deployed the bug:** the latest merged PR from `promote/<env>`. Its only
   change is the digests in `deploy/values-<env>.yaml`.
2. **Open the revert PR.** On the merged PR, click **Revert**; GitHub opens a PR from
   `revert-<n>-promote/<env>`. Or locally:
   ```bash
   git switch main && git pull
   git switch -c revert-<env>-promotion
   git revert -m 1 <merge commit of the promotion PR>
   git push -u origin revert-<env>-promotion
   ```
   In the description, say what's broken and link the alert or incident.
3. **Checks.** The environment's required check (**staging promotion only** / **prod promotion only**)
   treats a person's PR that changes `deploy/values-<env>.yaml` as a manual change: every digest it
   adds must be one the environment **ran before** (in the file's history on `main`), or pass the
   promotion rules (signed by cd; for prod, also what staging runs on `main`). A revert only brings
   back earlier digests, so it passes. A "rollback" to any other image fails.
4. **Approval and merge.** A teammate (not the author) approves and merges. No `production`
   environment approval is needed: the change is in `deploy/`, not Terraform.
5. **Argo CD redeploys** the previous images within about a minute. They're still in ECR (tags are
   immutable and images are referenced by digest), so nothing is rebuilt.
6. **Verify** (read-only access is enough in prod):
   ```bash
   aws eks update-kubeconfig --name g4-merlion-<env> --region us-east-1
   kubectl -n bank get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
   curl -s -o /dev/null -w '%{http_code}\n' https://<app hostname>/ready
   ```
   Prod's hostname is `merlion.sctp-sandbox.com`, staging's `merlion-staging.sctp-sandbox.com`. The
   digests match the reverted values file, the `bank-of-anthos` app in Argo CD is **Synced** and
   **Healthy**, and the error rate and latency in Grafana are back to normal.
7. **Fix forward** in `merlion-bank-app` (a fix, or a revert of the bad commit); its merge builds new
   images and cd opens a new staging promotion.

## Staging specifics

- **The open staging promotion PR may still carry the bug.** cd keeps one `promote/staging` PR open
  and updates it on every app merge. Until the fix is merged in the app repo, don't approve it.
- **Fixing forward is often quicker than a revert** in staging: the app fix goes through the normal
  path and replaces the bad version.

## Prod specifics

- **Staging still runs the bad version** after a prod rollback, so **don't run promote-prod again**
  until a fix has gone through staging. promote-prod copies staging's digests.

## Don't

- **`kubectl rollout undo` or Argo CD's rollback button:** people are read-only in prod, and Argo CD's
  self-heal puts back what's on `main` within minutes in both environments. Only a change in Git sticks.
- **Edit a values file by hand to an image the environment never ran** and cd didn't sign: the check
  rejects it. New images arrive only through promotions.

## Limits

- **Data isn't rolled back.** A revert changes the images, not the databases. Bank of Anthos runs no
  schema migrations on deploy, so a code rollback is safe here. A release that changes the schema
  would need a backward-compatible migration (or a restore from an RDS snapshot), planned before it
  ships.
- A rollback needs a teammate's approval, like every change to `main`. That's slower than a button
  in Argo CD, but it keeps maker-checker and the audit trail for every change.
- A rollback waits on `plan staging` like every PR, so it can't be merged while the CI roles are
  broken (after the nightly cleanup): restore them first.
