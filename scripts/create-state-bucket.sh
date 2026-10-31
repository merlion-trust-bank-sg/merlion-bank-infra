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

# 0 = exists and is ours; 404 = free to create; 403 = someone else's bucket or no permission
set +e
ERR="$(aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" 2>&1 >/dev/null)"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  echo "Bucket $BUCKET already exists and is owned by $ACCOUNT"
elif grep -q '(404)' <<<"$ERR"; then
  echo "Creating $BUCKET in $REGION"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
elif grep -q '(403)' <<<"$ERR"; then
  echo "ERROR: $BUCKET exists but is not owned by account $ACCOUNT, or you lack s3:ListBucket on it." >&2
  echo "       Do NOT reuse it. Check the account/profile you are logged in to." >&2
  exit 1
else
  echo "ERROR: unexpected response checking $BUCKET: $ERR" >&2
  exit 1
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# Keep old state versions for 90 days, clean up failed uploads
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" \
  --lifecycle-configuration '{"Rules":[{"ID":"state-history","Status":"Enabled","Filter":{},
   "NoncurrentVersionExpiration":{"NoncurrentDays":90},
   "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'

# TLS only + block deleting the bucket or permanently deleting state versions.
# s3:DeleteObject stays allowed: Terraform deletes its .tflock files, and on a
# versioned bucket that only adds a delete marker (history is kept).
aws s3api put-bucket-policy --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT" --policy "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*",
  "Resource":["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"],
  "Condition":{"Bool":{"aws:SecureTransport":"false"}}},
 {"Sid":"DenyStateDeletion","Effect":"Deny","Principal":"*",
  "Action":["s3:DeleteBucket","s3:DeleteObjectVersion"],
  "Resource":["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"]}
]}
JSON
)"
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging \
  'TagSet=[{Key=Project,Value=merlion-trust-bank},{Key=ManagedBy,Value=cli}]'
echo "State bucket ready: $BUCKET ($REGION)"
