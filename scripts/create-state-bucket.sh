#!/usr/bin/env bash
# INF-02 step 1 - create the Terraform state bucket ONCE (from WSL, as an admin).
#   scripts/create-state-bucket.sh            # uses the account you are logged in to
# Bucket: merlion-tfstate-<account-id>-use1, versioned, encrypted (SSE-KMS),
# public access blocked, TLS-only. Locking uses S3 lock files (use_lockfile),
# so no DynamoDB lock table is needed (DynamoDB locking is deprecated).
set -euo pipefail
REGION="${REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${G:?set G to your group id, e.g. G=g3}-merlion-tfstate-${ACCOUNT}-use1"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists"
else
  # us-east-1 is the one region that must NOT get a LocationConstraint
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*",
 "Action":"s3:*","Resource":["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"],
 "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
)"
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging \
  'TagSet=[{Key=Project,Value=merlion-trust-bank},{Key=ManagedBy,Value=cli}]'
echo "State bucket ready: $BUCKET ($REGION)"
