#!/usr/bin/env bash
# Put back what the training account's nightly cleanup (aws-nuke) strips from roles it otherwise keeps.
#
# Since the Project tag exemption, the cleanup keeps our tagged roles, buckets and state, but still
# deletes every role's inline policies and policy attachments (they can't be tagged). The roles can then
# be assumed but can do nothing: CI fails with 403 on the state bucket, nodes can't pull images, the
# add-ons lose AWS access. Re-applying bootstrap and staging from main recreates them.
#
# For each layer (bootstrap, then envs/<env>) this plans from main and:
#   - applies straight away if the plan only creates inline policies / policy attachments
#   - otherwise prints the other changes and asks before applying
# If the JWT secret got a new version, it then refreshes the Kubernetes Secrets and restarts the app.
# Before the env plan it also puts back the EKS cluster security group's rules (not in Terraform).
#
# Prod is restored the same way, by the break-glass holder only: the cleanup strips the pipeline's own
# roles, so the pipeline can't restore prod. It asks for the reason, and writes a record of the run to
# the Object Lock audit bucket (deploys/prod/), next to the pipeline's deploy records.
#
# If bootstrap itself is gone (state bucket missing), use scripts/rebuild-bootstrap.sh instead.
#
# Run as an account admin, with your own AWS profile for account 255945442255, from inside a
# merlion-bank-infra checkout:
#   AWS_PROFILE=<your profile> scripts/restore-iam.sh          staging
#   AWS_PROFILE=<your profile> scripts/restore-iam.sh prod     prod (break-glass holder only)
set -euo pipefail

ENV="${1:-staging}"
case "$ENV" in staging | prod) ;; *) echo "usage: restore-iam.sh [staging|prod]" >&2; exit 1 ;; esac

ACCOUNT_ID="255945442255"
REGION="us-east-1"
NAMESPACE="bank" # where Argo CD deploys the app (deploy/platform/<env>/bank-of-anthos.yaml)
CLUSTER="g4-merlion-$ENV"
NODEGROUP="$CLUSTER-default"
AUDIT_BUCKET="g4-merlion-audit-$ACCOUNT_ID"
# The only person allowed to restore prod (cluster admin in envs/prod/eks.tf); everyone else is read-only
BREAK_GLASS_HOLDER="arn:aws:iam::$ACCOUNT_ID:user/students/ce13/yqyeoh"
LAYERS=(bootstrap "envs/$ENV")
# envs/prod creates everything with count (prod can be switched off), so its addresses carry [0]
if [ "$ENV" = prod ]; then EKS_MODULE="module.eks[0]"; else EKS_MODULE="module.eks"; fi

say() { printf '\n==> %s\n' "$*"; }

# The EKS cluster security group is created by EKS, not Terraform, so a plan doesn't show its rules.
# The cleanup strips them (it removes a group's rules, then fails to delete the group because it's in
# use). Without them nodes can't reach the control plane or any AWS API and never join the cluster
# (NodeCreationFailure). Put back the two rules EKS creates: all traffic within the group, all outbound.
restore_cluster_sg() {
  local sg rules
  sg="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null)" || return 0
  [ -n "$sg" ] && [ "$sg" != None ] || return 0
  rules="$(aws ec2 describe-security-group-rules --region "$REGION" --filters Name=group-id,Values="$sg" \
    --query 'SecurityGroupRules[].[IsEgress,IpProtocol,CidrIpv4,ReferencedGroupInfo.GroupId]' --output text)"
  if ! grep -qE "^False\s+-1\s+None\s+$sg$" <<<"$rules"; then
    echo "Cluster security group $sg: putting back 'all traffic from itself'"
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg" \
      --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$sg}]" >/dev/null
    sg_restored=true
  fi
  if ! grep -qE "^True\s+-1\s+0\.0\.0\.0/0\s+None$" <<<"$rules"; then
    echo "Cluster security group $sg: putting back 'all outbound'"
    aws ec2 authorize-security-group-egress --region "$REGION" --group-id "$sg" \
      --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
    sg_restored=true
  fi
}

# Prod only: a record of this break-glass run in the Object Lock audit bucket, next to the pipeline's
# deploy records (deploys/prod/, same naming). Written on exit, so a failed or stopped run is recorded
# too. Admins can add objects there; nobody can delete them.
record_restore() {
  local status=$? key file
  [ "$ENV" = prod ] && [ -n "${START:-}" ] || return 0
  file="$(mktemp)"
  jq -n --arg env "$ENV" --arg reason "$REASON" --arg start "$START" \
    --arg end "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg who "$(aws sts get-caller-identity --query Arn --output text)" \
    --arg sha "$(git -C "$ROOT" rev-parse HEAD)" --argjson status "$status" \
    --argjson sg "$sg_restored" --argjson nodes "$nodes_replaced" --argjson off "$env_off" \
    --argjson applied "$(printf '%s\n' "${applied[@]+"${applied[@]}"}" | jq -s .)" \
    '{kind: "break-glass-restore", environment: $env, reason: $reason, actor: $who,
      started_at: $start, finished_at: $end, result: (if $status == 0 then "succeeded" else "failed (exit \($status))" end),
      commit: {sha: $sha, ref: "main"}, tool: "restore-iam.sh (local, outside the pipeline)",
      env_switched_off: $off, cluster_security_group_rules_restored: $sg, node_group_replaced: $nodes,
      terraform_applied: $applied}' >"$file"
  key="deploys/prod/$(date -u +%Y-%m-%dT%H%M%SZ)-break-glass-restore-$(git -C "$ROOT" rev-parse --short=7 HEAD).json"
  if aws s3api put-object --bucket "$AUDIT_BUCKET" --key "$key" --body "$file" \
    --content-type application/json --checksum-algorithm SHA256 >/dev/null; then
    echo "Recorded s3://$AUDIT_BUCKET/$key"
  else
    echo "WARNING: couldn't write the restore record; record this run by hand (incident notes)." >&2
  fi
  rm -f "$file"
}
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "Needs jq (brew install jq)."

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this from inside a merlion-bank-infra checkout."
[ -d "$ROOT/bootstrap" ] || die "$ROOT doesn't look like merlion-bank-infra."

actual="$(aws sts get-caller-identity --query Account --output text)" || die "No AWS credentials."
[ "$actual" = "$ACCOUNT_ID" ] || die "Credentials are for $actual, expected $ACCOUNT_ID (set AWS_PROFILE to your profile for it)."

# Applying from a branch that lacks something on main destroys it, so always main, up to date, clean
say "Checking out main"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || die "Uncommitted changes in $ROOT; commit or stash them first."
git -C "$ROOT" switch --quiet main
git -C "$ROOT" pull --quiet --ff-only

aws s3api head-bucket --bucket "g4-merlion-bootstrap-tfstate-$ACCOUNT_ID" 2>/dev/null \
  || die "The bootstrap state bucket is gone: the cleanup took more than IAM. Use scripts/rebuild-bootstrap.sh."

# Prod: break-glass only. People are read-only in prod and changes go through the approved pipeline;
# this exists because the cleanup strips the pipeline's own roles every night.
if [ "$ENV" = prod ]; then
  say "PROD restore (break-glass)"
  caller="$(aws sts get-caller-identity --query Arn --output text)"
  [ "$caller" = "$BREAK_GLASS_HOLDER" ] \
    || die "Prod is restored by the break-glass holder only ($BREAK_GLASS_HOLDER); you are $caller."
  echo "This changes production outside the pipeline. Only the break-glass holder runs it, and the run"
  echo "is recorded in s3://$AUDIT_BUCKET/deploys/prod/."
  read -r -p "Reason (e.g. 'nightly cleanup stripped IAM, node group DEGRADED'): " REASON
  [ -n "$REASON" ] || die "A reason is required for a prod restore."
  START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  trap record_restore EXIT
fi
applied=()

jwt_rotated=false
nodes_replaced=false
env_off=false
sg_restored=false

for layer in "${LAYERS[@]}"; do
  dir="$ROOT/$layer"
  plan="$dir/restore.tfplan"
  extra=()
  # The cleanup also deletes the node group's Auto Scaling group and launch template. EKS can't repair
  # a node group without its ASG (status DEGRADED, AutoScalingGroupNotFound), so replace it.
  if [ "$layer" = "envs/$ENV" ]; then
    # Prod can be switched off (enabled = false): then only bootstrap needs restoring
    if [ "$ENV" = prod ] && [ "$(terraform -chdir="$dir" output -raw enabled 2>/dev/null || echo true)" = false ]; then
      say "envs/prod is switched off (enabled = false): nothing to restore there"
      env_off=true
      continue
    fi
    say "$layer: EKS cluster security group"
    restore_cluster_sg
    ng_issues="$(aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEGROUP" --query 'nodegroup.health.issues[].code' --output text 2>/dev/null || true)"
    ng_status="$(aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEGROUP" --query 'nodegroup.status' --output text 2>/dev/null || true)"
    if [ "$ng_status" = CREATE_FAILED ]; then
      echo "Node group is CREATE_FAILED (a previous run's nodes couldn't join): it will be replaced."
      nodes_replaced=true
    elif grep -qE "AutoScalingGroupNotFound|Ec2LaunchTemplateNotFound" <<<"$ng_issues"; then
      echo "Node group lost its Auto Scaling group / launch template: it will be replaced (~10 minutes)."
      extra=("-replace=$EKS_MODULE.aws_eks_node_group.default")
      nodes_replaced=true
    fi
  fi
  say "$layer: plan"
  terraform -chdir="$dir" init -input=false >/dev/null
  set +e
  terraform -chdir="$dir" plan -input=false -lock-timeout=5m -detailed-exitcode -out="$plan" "${extra[@]+"${extra[@]}"}" >/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 1 ] || { rm -f "$plan"; die "$layer: plan failed; run terraform plan there to see why."; }
  if [ "$rc" -eq 0 ]; then
    echo "No changes."
    rm -f "$plan"
    continue
  fi

  changes="$(terraform -chdir="$dir" show -json "$plan" | jq -c '[.resource_changes[]
    | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | {address, type, actions: (.change.actions | join(","))}]')"

  echo "Restoring:"
  jq -r '.[] | select(.actions == "create" and (.type == "aws_iam_role_policy" or .type == "aws_iam_role_policy_attachment"))
    | "  + \(.address)"' <<<"$changes"

  other="$(jq -r '.[] | select((.actions == "create" and (.type == "aws_iam_role_policy" or .type == "aws_iam_role_policy_attachment")) | not)
    | "  \(.actions): \(.address)"' <<<"$changes")"

  if [ -n "$other" ]; then
    echo
    echo "Also in the plan (not an IAM restore, review it):"
    echo "$other"
    if grep -q "delete" <<<"$other"; then
      echo
      echo "!! The plan destroys or replaces something. Check it with:"
      echo "   terraform -chdir=$dir show $plan"
    fi
    read -r -p "Apply $layer anyway? [y/N] " ok
    [ "$ok" = y ] || { rm -f "$plan"; die "Stopped before applying $layer."; }
  fi

  grep -q "aws_secretsmanager_secret_version.jwt" <<<"$other" && jwt_rotated=true

  say "$layer: apply"
  terraform -chdir="$dir" apply -input=false "$plan"
  rm -f "$plan"
  applied+=("$(jq -c --arg l "$layer" '{layer: $l, changes: .}' <<<"$changes")")
done

if $env_off; then
  say "Done (bootstrap only). Re-run any CI job that failed with 403 / AccessDenied."
  exit 0
fi

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

if $nodes_replaced; then
  say "Waiting for the new nodes to be Ready"
  until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge 1 ]; do sleep 10; done
  kubectl wait --for=condition=Ready node --all --timeout=10m
  # Pods from the terminated nodes linger in Error; delete them so their Deployments start new ones
  kubectl -n "$NAMESPACE" delete pod --field-selector=status.phase=Failed --ignore-not-found
fi

# A new JWT key, or pods that missed secret refreshes while the add-ons had no AWS access
if $jwt_rotated || $nodes_replaced; then
  say "Refreshing the Kubernetes Secrets and restarting the app (logged-in users are logged out)"
  # After new nodes, External Secrets' webhook may still be starting, and it validates every change to
  # an ExternalSecret; wait for it, or the annotate below is refused ("no endpoints available")
  kubectl -n external-secrets rollout status deployment --timeout=10m
  # All namespaces: the app's secrets and Argo CD's GitHub App credentials (argocd)
  kubectl annotate externalsecret --all -A force-sync="$(date +%s)" --overwrite
  sleep 15 # External Secrets refreshes within seconds of the annotation
  kubectl -n "$NAMESPACE" rollout restart deployment
  kubectl -n "$NAMESPACE" rollout status deployment --timeout=10m
fi

say "Health check"
kubectl get nodes
not_running="$(kubectl get pods -A --no-headers | grep -vE ' (Running|Completed) ' || true)"
if [ -n "$not_running" ]; then
  echo "Pods not Running:"; echo "$not_running"
else
  echo "All pods Running."
fi
# The ALB only answers for this hostname; its own *.elb.amazonaws.com address returns 404
echo "App: https://$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{.items[0].spec.rules[0].host}')"

say "Done. Re-run any CI job that failed with 403 / AccessDenied."
