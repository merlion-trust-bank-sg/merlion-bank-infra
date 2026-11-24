#!/usr/bin/env bash
# Repair an environment after the training account's nightly cleanup. Called by the restore workflow
# (.github/workflows/restore.yml) once the CI roles have their policies back; the same steps as
# scripts/restore-iam.sh, run by the env's own pipeline roles.
#
#   restore-env.sh check <env>     does the cluster exist; does the node group need replacing
#   restore-env.sh plan <env>      terraform plan (replacing the node group if check said so)
#   restore-env.sh sg <env>        put back the EKS cluster security group's rules
#   restore-env.sh after <env>     wait for new nodes, refresh secrets, restart the bank, health check
#
# Inputs from earlier steps come in as environment variables (REPLACE, NODES_REPLACED, JWT_ROTATED);
# results go to $GITHUB_OUTPUT and $GITHUB_STEP_SUMMARY. Run from the repo root.
set -euo pipefail

STEP="${1:?step}"
ENV="${2:?env}"
case "$ENV" in staging | prod) ;; *) echo "env must be staging or prod" >&2; exit 1 ;; esac

CLUSTER="g4-merlion-$ENV"
NODEGROUP="$CLUSTER-default"
NAMESPACE="bank" # where Argo CD deploys the app
DIR="envs/$ENV"
# envs/prod creates everything with count (prod can be switched off), so its addresses carry [0]
if [ "$ENV" = prod ]; then EKS_MODULE="module.eks[0]"; else EKS_MODULE="module.eks"; fi
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

check() {
  # Prod can be switched off (enabled = false), and staging is torn down every evening: no cluster
  # means nothing to repair (bringing an env up is tf-apply's job, not a restore's)
  if [ "$ENV" = prod ] && [ "$(terraform -chdir="$DIR" output -raw enabled 2>/dev/null || echo true)" = false ]; then
    echo "envs/prod is switched off (enabled = false): nothing to restore" | tee -a "$SUMMARY"
    echo "exists=false" >>"$OUT"
    return
  fi
  local err
  if ! err="$(aws eks describe-cluster --name "$CLUSTER" 2>&1 >/dev/null)"; then
    # Anything but "not found" (e.g. AccessDenied, policies not attached yet) must fail, not skip
    grep -q ResourceNotFoundException <<<"$err" || { echo "$err" >&2; exit 1; }
    echo "No $CLUSTER cluster: nothing to restore in $ENV. Bring it up with tf-apply (Run workflow)." | tee -a "$SUMMARY"
    echo "exists=false" >>"$OUT"
    return
  fi
  echo "exists=true" >>"$OUT"

  # The cleanup deletes the node group's Auto Scaling group and launch template. EKS can't repair a
  # node group without them (DEGRADED, AutoScalingGroupNotFound), so it's replaced.
  local status issues
  status="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query 'nodegroup.status' --output text 2>/dev/null || true)"
  issues="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query 'nodegroup.health.issues[].code' --output text 2>/dev/null || true)"
  if [ "$status" = CREATE_FAILED ]; then
    # Terraform marks a failed create as tainted, so the plan replaces it without -replace
    echo "Node group is CREATE_FAILED: the plan replaces it." | tee -a "$SUMMARY"
    echo "nodes_replaced=true" >>"$OUT"
  elif grep -qE "AutoScalingGroupNotFound|Ec2LaunchTemplateNotFound" <<<"$issues"; then
    echo "Node group lost its Auto Scaling group / launch template: replacing it (~10 minutes)." | tee -a "$SUMMARY"
    echo "replace=$EKS_MODULE.aws_eks_node_group.default" >>"$OUT"
    echo "nodes_replaced=true" >>"$OUT"
  else
    echo "Node group $NODEGROUP: ${status:-not found}, nothing to replace."
    echo "nodes_replaced=false" >>"$OUT"
  fi
}

plan() {
  local extra=() code=0
  [ -z "${REPLACE:-}" ] || extra=("-replace=$REPLACE")
  terraform -chdir="$DIR" plan -lock-timeout=5m -detailed-exitcode -out="$ENV.tfplan" "${extra[@]+"${extra[@]}"}" || code=$?
  [ "$code" -ne 1 ] || exit 1
  echo "changes=$([ "$code" -eq 2 ] && echo true || echo false)" >>"$OUT"

  # A new JWT signing key means the app's Secrets must be refreshed and the bank restarted
  local jwt
  jwt="$(terraform -chdir="$DIR" show -json "$ENV.tfplan" | jq '[.resource_changes[]?
    | select((.address | test("aws_secretsmanager_secret_version\\.jwt")) and .change.actions != ["no-op"])] | length')"
  echo "jwt_rotated=$([ "$jwt" -gt 0 ] && echo true || echo false)" >>"$OUT"

  {
    echo "### Terraform plan: $ENV"
    echo "Commit \`${GITHUB_SHA::7}\`. Only what's already on \`main\`, plus the repairs above."
    echo '```'
    terraform -chdir="$DIR" show -no-color "$ENV.tfplan" | tail -c 60000
    echo '```'
  } >>"$SUMMARY"
}

# The EKS cluster security group is created by EKS, not Terraform, so a plan doesn't show its rules.
# The cleanup strips them; without them nodes can't reach the control plane and never join
# (NodeCreationFailure). Put back the two rules EKS creates: all traffic within the group, all outbound.
sg() {
  local group rules
  group="$(aws eks describe-cluster --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
  rules="$(aws ec2 describe-security-group-rules --filters Name=group-id,Values="$group" \
    --query 'SecurityGroupRules[].[IsEgress,IpProtocol,CidrIpv4,ReferencedGroupInfo.GroupId]' --output text)"
  if ! grep -qE "^False\s+-1\s+None\s+$group$" <<<"$rules"; then
    echo "Cluster security group $group: putting back 'all traffic from itself'" | tee -a "$SUMMARY"
    aws ec2 authorize-security-group-ingress --group-id "$group" \
      --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$group}]" >/dev/null
  fi
  if ! grep -qE "^True\s+-1\s+0\.0\.0\.0/0\s+None$" <<<"$rules"; then
    echo "Cluster security group $group: putting back 'all outbound'" | tee -a "$SUMMARY"
    aws ec2 authorize-security-group-egress --group-id "$group" \
      --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null
  fi
  echo "Cluster security group $group: rules in place."
}

after() {
  aws eks update-kubeconfig --name "$CLUSTER" >/dev/null

  if [ "${NODES_REPLACED:-false}" = true ]; then
    echo "Waiting for the new nodes to be Ready"
    # shellcheck disable=SC2016 # expanded by the inner bash, on every loop
    timeout 900 bash -c 'until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")" -ge 1 ]; do sleep 10; done'
    kubectl wait --for=condition=Ready node --all --timeout=10m
    # Pods from the terminated nodes linger in Error; delete them so their Deployments start new ones
    kubectl -n "$NAMESPACE" delete pod --field-selector=status.phase=Failed --ignore-not-found
  fi

  # A new JWT key, or pods that missed secret refreshes while the add-ons had no AWS access
  if [ "${JWT_ROTATED:-false}" = true ] || [ "${NODES_REPLACED:-false}" = true ]; then
    echo "Refreshing the Kubernetes Secrets and restarting the bank (logged-in users are logged out)"
    # After new nodes, External Secrets' webhook may still be starting, and it validates every change
    # to an ExternalSecret; wait for it, or the annotate below is refused ("no endpoints available")
    kubectl -n external-secrets rollout status deployment --timeout=10m
    # All namespaces: the app's secrets and Argo CD's GitHub App credentials (argocd)
    kubectl annotate externalsecret --all -A force-sync="$(date +%s)" --overwrite
    sleep 15 # External Secrets refreshes within seconds of the annotation
    kubectl -n "$NAMESPACE" rollout restart deployment
    kubectl -n "$NAMESPACE" rollout status deployment --timeout=10m
  fi

  local not_running host
  not_running="$(kubectl get pods -A --no-headers | grep -vE ' (Running|Completed) ' || true)"
  # The ALB only answers for this hostname; its own *.elb.amazonaws.com address returns 404
  host="$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)"
  {
    echo "### Health: $ENV"
    echo '```'
    kubectl get nodes
    echo '```'
    if [ -n "$not_running" ]; then
      echo "Pods not Running:"
      echo '```'
      echo "$not_running"
      echo '```'
    else
      echo "All pods Running."
    fi
    [ -z "$host" ] || echo "App: https://$host"
  } | tee -a "$SUMMARY"
}

case "$STEP" in
  check) check ;;
  plan) plan ;;
  sg) sg ;;
  after) after ;;
  *) echo "unknown step: $STEP" >&2; exit 1 ;;
esac
