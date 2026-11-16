#!/usr/bin/env bash
# Install what Argo CD needs before it can read this repo, then Argo CD, and hand it everything else.
#
# Terraform can't install software into a cluster it creates in the same run, so this runs after
# `terraform apply` in envs/<env>: in the pipeline (as g4-merlion-ci-<env>) and by hand after a rebuild.
# Safe to re-run: with no changes, each step leaves the cluster as it is.
#
# Order, as for a private repo:
#   1. External Secrets (Helm), so that
#   2. Argo CD's GitHub App credentials can be copied from Secrets Manager (repo-creds.yaml), and
#   3. Argo CD (Helm) can read the repo from its first sync.
# External Secrets and Argo CD are installed only on a new cluster; Argo CD then manages both from
# deploy/platform/<env>/ (external-secrets.yaml, argocd.yaml), with the same versions and values.
#
#   deploy/bootstrap/bootstrap.sh staging                  Argo CD follows main (the pipeline)
#   deploy/bootstrap/bootstrap.sh staging SCRUM-23-addons  test an unmerged branch (pushed to GitHub)
#   REINSTALL=1 deploy/bootstrap/bootstrap.sh staging      break-glass: Helm upgrade both from Git again
#                                                          (only where Helm installed them first)
set -euo pipefail

ENV="${1:?usage: bootstrap.sh <staging|prod> [branch]}"
case "$ENV" in staging | prod) ;; *) echo "unknown env: $ENV" >&2; exit 1 ;; esac

# Branch Argo CD reads deploy/platform/<env> from. Only for testing before a merge; the files in
# Git always say main.
BRANCH="${2:-main}"

ROOT="$(git rev-parse --show-toplevel)"
REGION="us-east-1"
PLATFORM="$ROOT/deploy/platform/$ENV"

# Chart versions come from the Argo CD ApplicationSets that take the charts over, so the two can't drift
chart_version() {
  awk -v c="$2" '$0 ~ "chart: "c"$" {f=1} f && /targetRevision:/ {print $2; exit}' "$1"
}
ARGOCD_CHART_VERSION="$(chart_version "$PLATFORM/argocd.yaml" argo-cd)"
ESO_CHART_VERSION="$(chart_version "$PLATFORM/external-secrets.yaml" external-secrets)"
[ -n "$ARGOCD_CHART_VERSION" ] && [ -n "$ESO_CHART_VERSION" ] ||
  { echo "chart versions not found in $PLATFORM" >&2; exit 1; }

# Facts only Terraform knows. The VPC is recreated on every rebuild, so its ID can't live in Git.
TF="terraform -chdir=$ROOT/envs/$ENV"

# Prod can be switched off (envs/prod var.enabled): then there's no cluster to bootstrap
if [ "$($TF output -raw enabled 2>/dev/null || echo true)" = false ]; then
  echo "$ENV is switched off (envs/$ENV enabled = false): nothing to bootstrap."
  exit 0
fi
CLUSTER="$($TF output -raw eks_cluster_name)"
VPC_ID="$($TF output -raw vpc_id)"
APP_SECRETS="$($TF output -json app_secrets)"
DB_HOSTS="$($TF output -json db_hosts)"
ACCOUNTS_DB_SECRET="$(jq -r .accounts_db <<<"$APP_SECRETS")"
LEDGER_DB_SECRET="$(jq -r .ledger_db <<<"$APP_SECRETS")"
JWT_SECRET="$(jq -r .jwt <<<"$APP_SECRETS")"
ACCOUNTS_DB_HOST="$(jq -r .accounts <<<"$DB_HOSTS")"
LEDGER_DB_HOST="$(jq -r .ledger <<<"$DB_HOSTS")"
APP_HOSTNAME="$($TF output -raw app_hostname)"
CERTIFICATE_ARN="$($TF output -raw certificate_arn)"
DNS_ZONE_ID="$($TF output -raw dns_zone_id)"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" >/dev/null
KUBECTL="kubectl --context $CLUSTER"

# Installed by Helm only when missing (or REINSTALL=1). Once Argo CD manages a chart, Helm must not
# touch it again, or the two would fight over it.
needs_install() { # <namespace> <deployment>
  [ "${REINSTALL:-0}" = 1 ] || ! $KUBECTL -n "$1" get deployment "$2" >/dev/null 2>&1
}

echo "==> External Secrets $ESO_CHART_VERSION"
if needs_install external-secrets external-secrets; then
  helm upgrade --install external-secrets external-secrets \
    --repo https://charts.external-secrets.io \
    --kube-context "$CLUSTER" \
    --version "$ESO_CHART_VERSION" \
    --namespace external-secrets --create-namespace \
    --values "$ROOT/deploy/bootstrap/external-secrets-values.yaml" \
    --wait --timeout 10m
else
  echo "Already installed; managed by Argo CD (deploy/platform/$ENV/external-secrets.yaml)"
fi

echo "==> Argo CD's GitHub App credentials"
$KUBECTL create namespace argocd --dry-run=client -o yaml | $KUBECTL apply -f -
export ENV
# The External Secrets webhook may not have its certificate yet right after a fresh install
for attempt in 1 2 3 4 5 6; do
  envsubst '${ENV}' <"$ROOT/deploy/bootstrap/repo-creds.yaml" | $KUBECTL apply -f - && break
  [ "$attempt" = 6 ] && exit 1
  echo "External Secrets webhook not ready yet; retrying in 20s"
  sleep 20
done
if ! $KUBECTL -n argocd wait externalsecret/github-repo-creds --for=condition=Ready --timeout=3m; then
  $KUBECTL -n argocd describe externalsecret github-repo-creds | tail -5 >&2
  echo "No GitHub App credentials for $ENV. An org owner runs deploy/bootstrap/put-argocd-github-app.sh $ENV (README)." >&2
  exit 1
fi

echo "==> Argo CD $ARGOCD_CHART_VERSION"
if needs_install argocd argocd-server; then
  # The OCI copy of the chart on ghcr.io: downloads from the GitHub release page (the classic Helm
  # repo) timed out with 504s
  helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd \
    --kube-context "$CLUSTER" \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd \
    --values "$ROOT/deploy/bootstrap/argocd-values.yaml" \
    --wait --timeout 10m
else
  echo "Already installed; managed by Argo CD (deploy/platform/$ENV/argocd.yaml)"
fi

# GitOps bridge: register this cluster with Argo CD and pass it the Terraform facts. See
# cluster-secret.yaml for why; envsubst fills in its ${...} placeholders from the variables above.
echo "==> Cluster facts for the add-ons"
VARS='${ENV} ${CLUSTER} ${REGION} ${VPC_ID} ${ACCOUNTS_DB_HOST} ${LEDGER_DB_HOST} ${ACCOUNTS_DB_SECRET} ${LEDGER_DB_SECRET} ${JWT_SECRET} ${APP_HOSTNAME} ${CERTIFICATE_ARN} ${DNS_ZONE_ID} ${BRANCH}'
export ENV CLUSTER REGION VPC_ID ACCOUNTS_DB_HOST LEDGER_DB_HOST ACCOUNTS_DB_SECRET LEDGER_DB_SECRET JWT_SECRET APP_HOSTNAME CERTIFICATE_ARN DNS_ZONE_ID BRANCH
envsubst "$VARS" <"$ROOT/deploy/bootstrap/cluster-secret.yaml" |
  $KUBECTL apply -f -

# Before any Application uses them
echo "==> Argo CD projects"
$KUBECTL apply -f "$ROOT/deploy/bootstrap/projects.yaml"

echo "==> Root application: deploy/platform/$ENV on $BRANCH"
if [ "$BRANCH" != "main" ]; then
  # Argo CD reads from GitHub, so the branch must exist there
  git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null ||
    { echo "branch $BRANCH isn't on GitHub; push it first" >&2; exit 1; }
fi
sed "s|targetRevision: main|targetRevision: $BRANCH|" "$ROOT/deploy/bootstrap/root-$ENV.yaml" |
  $KUBECTL apply -f -

echo "Done. Argo CD now installs everything in deploy/platform/$ENV from $BRANCH."
