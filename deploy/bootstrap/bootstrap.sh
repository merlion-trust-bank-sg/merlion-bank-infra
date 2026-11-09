#!/usr/bin/env bash
# Install Argo CD into an environment's cluster and hand it everything else.
#
# Terraform can't install software into a cluster it creates in the same run, so this runs after
# `terraform apply` in envs/<env>: in the pipeline (as g4-merlion-ci-<env>) and by hand after a rebuild.
# Safe to re-run: with no changes, each step leaves the cluster as it is.
#
#   deploy/bootstrap/bootstrap.sh staging                  Argo CD follows main (the pipeline)
#   deploy/bootstrap/bootstrap.sh staging SCRUM-23-addons  test an unmerged branch (pushed to GitHub)
set -euo pipefail

ENV="${1:?usage: bootstrap.sh <staging|prod> [branch]}"
case "$ENV" in staging | prod) ;; *) echo "unknown env: $ENV" >&2; exit 1 ;; esac

# Branch Argo CD reads deploy/platform/<env> from. Only for testing before a merge; the files in
# Git always say main.
BRANCH="${2:-main}"

ROOT="$(git rev-parse --show-toplevel)"
REGION="us-east-1"
ARGOCD_CHART_VERSION="10.17.0"

# Facts only Terraform knows. The VPC is recreated on every rebuild, so its ID can't live in Git.
TF="terraform -chdir=$ROOT/envs/$ENV"
CLUSTER="$($TF output -raw eks_cluster_name)"
VPC_ID="$($TF output -raw vpc_id)"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" >/dev/null
KUBECTL="kubectl --context $CLUSTER"

echo "==> Argo CD $ARGOCD_CHART_VERSION"
# The OCI copy of the chart on ghcr.io: downloads from the GitHub release page (the classic Helm
# repo) timed out with 504s
helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd \
  --kube-context "$CLUSTER" \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$ROOT/deploy/bootstrap/argocd-values.yaml" \
  --wait --timeout 10m

# GitOps bridge: register this cluster with Argo CD and pass it the Terraform facts. See
# cluster-secret.yaml for why; envsubst fills in its ${...} placeholders from the variables above.
echo "==> Cluster facts for the add-ons"
export ENV CLUSTER REGION VPC_ID
envsubst '${ENV} ${CLUSTER} ${REGION} ${VPC_ID}' <"$ROOT/deploy/bootstrap/cluster-secret.yaml" |
  $KUBECTL apply -f -

echo "==> Root application: deploy/platform/$ENV on $BRANCH"
if [ "$BRANCH" != "main" ]; then
  # Argo CD reads from GitHub, so the branch must exist there
  git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null ||
    { echo "branch $BRANCH isn't on GitHub; push it first" >&2; exit 1; }
fi
sed "s|targetRevision: main|targetRevision: $BRANCH|" "$ROOT/deploy/bootstrap/root-$ENV.yaml" |
  $KUBECTL apply -f -

echo "Done. Argo CD now installs everything in deploy/platform/$ENV from $BRANCH."
