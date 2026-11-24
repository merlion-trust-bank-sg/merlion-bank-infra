#!/usr/bin/env bash
# Restore an environment after the training account's nightly cleanup, through the pipeline.
#
# Does the one manual step (re-attach g4-merlion-ci-restore's own policy, only if the cleanup removed
# it), starts the restore workflow on main (.github/workflows/restore.yml) and follows the run. A prod
# restore waits in the run for a production reviewer to approve.
#
# Run with your own AWS profile for account 255945442255, from anywhere:
#   AWS_PROFILE=<your profile> scripts/restore.sh                    staging
#   AWS_PROFILE=<your profile> scripts/restore.sh prod               prod (needs the production approval)
#   AWS_PROFILE=<your profile> scripts/restore.sh staging "<reason>" if it isn't the nightly cleanup
#
# If the workflow can't run (e.g. the restore role or its policy is gone), use scripts/restore-iam.sh.
set -euo pipefail

ENV="${1:-staging}"
REASON="${2:-nightly cleanup}"
case "$ENV" in staging | prod) ;; *) echo "usage: restore.sh [staging|prod] [reason]" >&2; exit 1 ;; esac

ACCOUNT_ID="255945442255"
REPO="merlion-trust-bank-sg/merlion-bank-infra"
ROLE="g4-merlion-ci-restore"
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$ROLE"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

for cmd in aws gh jq; do command -v "$cmd" >/dev/null || die "Needs $cmd."; done
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub: gh auth login"

actual="$(aws sts get-caller-identity --query Account --output text)" || die "No AWS credentials."
[ "$actual" = "$ACCOUNT_ID" ] || die "Credentials are for $actual, expected $ACCOUNT_ID (set AWS_PROFILE to your profile for it)."

# A role with no permissions can't give itself any, so this one attach is done by a person
if aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' \
  --output text | tr '\t' '\n' | grep -qxF "$POLICY_ARN"; then
  echo "$ROLE already has its policy."
else
  echo "Re-attaching $ROLE's policy (removed by the nightly cleanup)"
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"
  sleep 10 # IAM is eventually consistent; the workflow uses the role within seconds
fi

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gh workflow run restore --repo "$REPO" --ref main -f environment="$ENV" -f reason="$REASON"

# gh doesn't return the new run's ID: find the first restore run created since the dispatch
echo "Waiting for the run to start"
run=""
for _ in $(seq 1 30); do
  run="$(gh run list --repo "$REPO" --workflow restore --event workflow_dispatch --limit 5 \
    --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"$started\")] | last | .databaseId // empty")"
  [ -n "$run" ] && break
  sleep 2
done
[ -n "$run" ] || die "Couldn't find the run; check https://github.com/$REPO/actions/workflows/restore.yml"

echo "https://github.com/$REPO/actions/runs/$run"
[ "$ENV" = staging ] || echo "Prod: the 'apply prod' job waits for a production reviewer to approve it in that run."
gh run watch "$run" --repo "$REPO" --exit-status
echo
echo "Done. Re-run any CI job that failed with 403 / AccessDenied."
