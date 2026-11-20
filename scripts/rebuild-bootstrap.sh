#!/usr/bin/env bash
# Rebuild the bootstrap layer after the training account's nightly cleanup (aws-nuke).
#
# The cleanup deletes the state buckets and CI roles, schedules the KMS keys for deletion, and leaves
# the customer managed IAM policies and the KMS aliases behind. Terraform's state went with the
# bucket, so this script:
#   1. checks it's the right account and that the state bucket really is gone
#   2. deletes KMS aliases that point at keys pending deletion (bootstrap creates new keys)
#   3. applies bootstrap with local state, importing the IAM policies that are left over
#   4. moves the state into the new state bucket
# It stops for you to review the plan before anything is created.
#
# Run as an account admin, with your own AWS profile for account 255945442255, from inside the repo:
#   AWS_PROFILE=<your profile> scripts/rebuild-bootstrap.sh
set -euo pipefail

ACCOUNT_ID="255945442255"
REGION="us-east-1"
PREFIX="g4-merlion"
LAYERS=(bootstrap staging prod)
ENVS=(staging prod)

# Works from any checkout of merlion-bank-infra: run it from inside the repo
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Run this from inside a merlion-bank-infra checkout." >&2; exit 1; }
[ -d "$ROOT/bootstrap" ] || { echo "$ROOT has no bootstrap/ folder." >&2; exit 1; }
BOOTSTRAP="$ROOT/bootstrap"
BACKEND="$BOOTSTRAP/backend.tf"
IMPORTS="$BOOTSTRAP/imports.tf"
PLAN="$BOOTSTRAP/bootstrap.tfplan"

aws_() { aws --region "$REGION" --output text "$@"; }
say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Put backend.tf back and remove the import blocks, however the script ends. Local state files are
# kept on failure: until migration succeeds they are the only copy.
cleanup() {
  git -C "$ROOT" checkout --quiet -- "$BACKEND" 2>/dev/null || true
  rm -f "$IMPORTS"
}
trap cleanup EXIT

# --- 1. Preconditions --------------------------------------------------------------------------
say "Checking account and current state"
actual="$(aws_ sts get-caller-identity --query Account)" || die "No AWS credentials. Set AWS_PROFILE."
[ "$actual" = "$ACCOUNT_ID" ] || die "Credentials are for account $actual, expected $ACCOUNT_ID."

[ -z "$(git -C "$ROOT" status --porcelain -- "$BOOTSTRAP")" ] ||
  die "bootstrap/ has uncommitted changes. Commit or discard them first."

if aws s3api head-bucket --bucket "$PREFIX-bootstrap-tfstate-$ACCOUNT_ID" 2>/dev/null; then
  die "The bootstrap state bucket still exists, so nothing to rebuild. Use a normal plan/apply."
fi

aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' |
  grep -q 'token.actions.githubusercontent.com' ||
  die "The GitHub OIDC provider is missing. It's shared by the account; ask whoever manages it."

# --- 2. Stale KMS aliases ------------------------------------------------------------------------
say "Removing KMS aliases that point at keys pending deletion"
for l in "${LAYERS[@]}"; do
  alias="alias/$PREFIX-$l-state"
  state="$(aws_ kms describe-key --key-id "$alias" --query KeyMetadata.KeyState 2>/dev/null || echo none)"
  case "$state" in
    none) echo "  $alias: not present" ;;
    PendingDeletion)
      aws kms delete-alias --region "$REGION" --alias-name "$alias"
      echo "  $alias: deleted (its key is pending deletion)" ;;
    *) die "$alias points at a key in state $state. Import it instead of creating a new one." ;;
  esac
done

# --- 3. Import blocks for the IAM policies the cleanup left behind --------------------------------
say "Finding leftover IAM policies"
policy_exists() { aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$1" >/dev/null 2>&1; }
add_import() {
  printf 'import {\n  to = %s\n  id = "arn:aws:iam::%s:policy/%s"\n}\n\n' "$1" "$ACCOUNT_ID" "$2" >>"$IMPORTS"
  echo "  import $2"
}

: >"$IMPORTS"
policy_exists "$PREFIX-ci-protect-bootstrap" &&
  add_import 'module.iam_ci.aws_iam_policy.protect_bootstrap' "$PREFIX-ci-protect-bootstrap"
for e in "${ENVS[@]}"; do
  policy_exists "$PREFIX-ci-$e-deploy" &&
    add_import "module.iam_ci.aws_iam_policy.deploy[\"$e\"]" "$PREFIX-ci-$e-deploy"
  policy_exists "$PREFIX-ci-$e-fence" &&
    add_import "module.iam_ci.aws_iam_policy.env_fence[\"$e\"]" "$PREFIX-ci-$e-fence"
  policy_exists "$PREFIX-$e-workload-boundary" &&
    add_import "module.iam_ci.aws_iam_policy.workload_boundary[\"$e\"]" "$PREFIX-$e-workload-boundary"
done
[ -s "$IMPORTS" ] || { rm -f "$IMPORTS"; echo "  none"; }

# --- 4. Plan with local state ---------------------------------------------------------------------
say "Planning with local state (backend disabled for the first apply)"
sed -i.orig '/^terraform {/,/^}/ s/^/# /' "$BACKEND" && rm -f "$BACKEND.orig"
rm -f "$BOOTSTRAP/.terraform/terraform.tfstate" "$BOOTSTRAP/terraform.tfstate" "$BOOTSTRAP/terraform.tfstate.backup"
terraform -chdir="$BOOTSTRAP" init -reconfigure -input=false
terraform -chdir="$BOOTSTRAP" plan -input=false -out="$PLAN"

summary="$(terraform -chdir="$BOOTSTRAP" show -no-color "$PLAN" | grep -E '^Plan:' || true)"
case "$summary" in
  *" 0 to destroy."*) ;;
  *) die "The plan would destroy something ($summary). Not applying." ;;
esac

echo
echo "Plan: $summary"
echo "Expect: 0 to destroy, about 45 to add, and the policies above imported and updated."
read -r -p "Apply this plan? Type 'yes': " answer
[ "$answer" = "yes" ] || die "Not applied. Nothing was created; the aliases above were removed."

# --- 5. Apply and move state into the new bucket ---------------------------------------------------
say "Applying"
terraform -chdir="$BOOTSTRAP" apply -input=false "$PLAN"
rm -f "$PLAN" "$IMPORTS"

say "Moving state into the new bucket"
git -C "$ROOT" checkout --quiet -- "$BACKEND"
terraform -chdir="$BOOTSTRAP" init -migrate-state -force-copy -input=false

say "Checking the migrated state"
if terraform -chdir="$BOOTSTRAP" plan -input=false -detailed-exitcode >/dev/null; then
  rm -f "$BOOTSTRAP/terraform.tfstate" "$BOOTSTRAP/terraform.tfstate.backup"
  say "Done. Bootstrap is rebuilt and its state is in $PREFIX-bootstrap-tfstate-$ACCOUNT_ID."
else
  die "The plan after migration isn't clean. Local state files are kept in bootstrap/; check before deleting them."
fi
