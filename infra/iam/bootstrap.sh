#!/usr/bin/env bash
# One-time AWS infra setup for SkyEye monitoring-prod.
#
# Prerequisites:
#   - aws cli v2 installed and configured with credentials that can:
#     iam:*, s3:*, ec2:CreateVpcEndpoint, ec2:AssociateIamInstanceProfile
#   - Run this from ANY machine (your laptop, CloudShell, or the EC2 itself).
#
# Idempotent-ish: re-running skips resources that already exist.

set -euo pipefail

# Disable aws cli pager (CloudShell defaults to less, which blocks scripts)
export AWS_PAGER=""

cd "$(dirname "$0")"

# ---------- Config ----------
ROLE_NAME="monitoring-prod-role"
INSTANCE_ID="i-0ae4722dc931e26a1"
REGION="ap-northeast-1"
VPC_ID="vpc-0fd495e58e33bd8c5"
SUBNET_ID="subnet-0ba2c44c6f8dfb4c9"

LOKI_BUCKET="skyeye-loki-chunks"
SNAP_BUCKET="skyeye-prometheus-snapshots"
# ----------------------------

echo "==> Resolving caller identity"
aws sts get-caller-identity

# ---------- IAM role + instance profile ----------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> IAM role $ROLE_NAME already exists — skipping create"
else
  echo "==> Creating IAM role $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://trust-policy.json \
    --description "SkyEye monitoring-prod: Loki chunks + Prom snapshots to S3"
fi

echo "==> Attaching inline S3 policy"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name skyeye-s3-rw \
  --policy-document file://s3-policy.json

if aws iam get-instance-profile --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> Instance profile $ROLE_NAME already exists — skipping"
else
  echo "==> Creating instance profile $ROLE_NAME"
  aws iam create-instance-profile --instance-profile-name "$ROLE_NAME"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
  echo "==> Waiting 10s for IAM eventual consistency"
  sleep 10
fi

# ---------- S3 buckets ----------
create_bucket() {
  local BUCKET="$1"
  local LIFECYCLE_FILE="$2"

  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    echo "==> Bucket $BUCKET already exists — skipping create"
  else
    echo "==> Creating bucket $BUCKET"
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi

  echo "==> Bucket $BUCKET: SSE-S3 encryption"
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  echo "==> Bucket $BUCKET: block public access"
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "==> Bucket $BUCKET: lifecycle $LIFECYCLE_FILE"
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET" \
    --lifecycle-configuration "file://$LIFECYCLE_FILE"
}

create_bucket "$LOKI_BUCKET" loki-lifecycle.json
create_bucket "$SNAP_BUCKET" snapshots-lifecycle.json

# ---------- VPC S3 Gateway Endpoint ----------
EXISTING_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
           "Name=service-name,Values=com.amazonaws.$REGION.s3" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_ENDPOINT" != "None" && -n "$EXISTING_ENDPOINT" ]]; then
  echo "==> S3 Gateway Endpoint already exists in VPC: $EXISTING_ENDPOINT"
else
  echo "==> Looking up route table for subnet $SUBNET_ID"
  RT_ID=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query 'RouteTables[0].RouteTableId' --output text)

  if [[ "$RT_ID" == "None" || -z "$RT_ID" ]]; then
    echo "==> Subnet has no explicit RT — using VPC main route table"
    RT_ID=$(aws ec2 describe-route-tables \
      --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi

  echo "==> Creating S3 Gateway Endpoint in $VPC_ID, attaching to RT $RT_ID"
  aws ec2 create-vpc-endpoint \
    --region "$REGION" \
    --vpc-id "$VPC_ID" \
    --service-name "com.amazonaws.$REGION.s3" \
    --route-table-ids "$RT_ID" \
    --vpc-endpoint-type Gateway
fi

# ---------- Attach instance profile to EC2 ----------
CURRENT_PROFILE=$(aws ec2 describe-iam-instance-profile-associations \
  --region "$REGION" \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
  --output text 2>/dev/null || echo "None")

if [[ "$CURRENT_PROFILE" == *"$ROLE_NAME"* ]]; then
  echo "==> Instance $INSTANCE_ID already has $ROLE_NAME attached — skipping"
else
  echo "==> Attaching instance profile $ROLE_NAME to $INSTANCE_ID"
  aws ec2 associate-iam-instance-profile \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=$ROLE_NAME"
fi

cat <<EOF

==> All done.

Verify from the monitoring-prod EC2 (wait ~60s for IMDS cache):

  TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token \\
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" \\
    http://169.254.169.254/latest/meta-data/iam/security-credentials/
  # → should print: $ROLE_NAME

  aws s3 ls s3://$LOKI_BUCKET/      # should succeed (empty is fine)
  aws s3 ls s3://$SNAP_BUCKET/      # should succeed

EOF
