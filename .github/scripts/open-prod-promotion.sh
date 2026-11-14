#!/usr/bin/env bash
# Open (or update) the prod promotion PR: deploy/values-prod.yaml gets exactly the digests staging runs
# on main. Run by promote-prod.yml, from a checkout of main.
#
#   1. copy the digests (copy-digests.py); if prod already runs them, close any stale PR and stop
#   2. commit and force-push promote/prod (one open prod promotion at most)
#   3. open or update the PR, saying which staging promotion it comes from and who ran it
#
# It never merges: someone other than whoever ran it approves (enforced by the "prod promotion only"
# check, from the commit's Promotion-run trailer), and merging is the prod deploy.
#
# Environment (set by the workflow):
#   GH_TOKEN, APP_SLUG   promotion App token and slug
#   BRANCH, FROM, TO     promote/prod, deploy/values-staging.yaml, deploy/values-prod.yaml
#   RUN_URL              this run, for the PR
#   SKIPPED              "true" if the staging health check was skipped
#   GITHUB_*             standard Actions variables
set -euo pipefail

# --- 1. Copy the digests ------------------------------------------------------------------------------
python3 .github/scripts/copy-digests.py "$FROM" "$TO"

if git diff --quiet; then
  echo "Prod already runs the digests staging runs; nothing to promote." >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  pr="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --state open --json number --jq '.[0].number')"
  if [ -n "$pr" ]; then
    gh pr close "$pr" --repo "$GITHUB_REPOSITORY" --delete-branch \
      --comment "Superseded: prod already runs the digests staging runs on main."
  fi
  exit 0
fi

# Which staging promotion these digests came from: the last commit on main that changed staging's file
from_sha="$(git log -1 --format=%H -- "$FROM")"
from_subject="$(git log -1 --format=%s -- "$FROM")"
from_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/commit/$from_sha"

# --- 2. Commit and push promote/prod ----------------------------------------------------------------
title="Promote staging to prod ($(sed -nE 's/.*merlion-bank-app ([0-9a-f]{7,}).*/\1/p' <<<"$from_subject" | head -1))"
[ "$title" = "Promote staging to prod ()" ] && title="Promote staging to prod (${from_sha::7})"

user_id="$(gh api "/users/${APP_SLUG}[bot]" --jq .id)"
git config user.name "${APP_SLUG}[bot]"
git config user.email "${user_id}+${APP_SLUG}[bot]@users.noreply.github.com"
git switch -c "$BRANCH"
# The trailer tells the "prod promotion only" check which run (and so which person) promoted, so it can
# require an approval from someone else. Only the App can push promote/prod, so it can't be forged.
git commit -qam "$title" -m "Promotion-run: $GITHUB_RUN_ID"
git push --force origin "$BRANCH"

# --- 3. Open or update the PR -------------------------------------------------------------------------
smoke="Staging's health check passed (\`/ready\`, \`/login\`)."
[ "$SKIPPED" = true ] && smoke="**Staging's health check was skipped** by whoever ran this; the reason should be in a comment below."

body="Sets \`$TO\` to the digests staging runs on \`main\`, as of [${from_sha::7}]($from_url) \"$from_subject\". Changes only image digests.

$smoke

Opened by [promote-prod run $GITHUB_RUN_ID]($RUN_URL), started by @$GITHUB_ACTOR. **Needs an approval from someone else; merging it is the prod deploy** (Argo CD syncs prod within ~3 minutes). The \`prod promotion only\` check confirms every digest equals staging's and was built and signed by merlion-bank-app's cd on \`main\`."

pr="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --state open --json number --jq '.[0].number')"
if [ -z "$pr" ]; then
  gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$BRANCH" --title "$title" --body "$body" >/dev/null
  pr="$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --state open --json number --jq '.[0].number')"
else
  gh pr edit "$pr" --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body" >/dev/null
fi

echo "Prod promotion PR: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$pr" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
