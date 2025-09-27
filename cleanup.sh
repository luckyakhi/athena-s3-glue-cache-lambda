#!/usr/bin/env bash
set -euo pipefail
pushd terraform >/dev/null

# Best effort: empty buckets first (ok if outputs not present)
DATA=$(terraform output -raw data_bucket 2>/dev/null || true)
RES=$(terraform output -raw athena_results_bucket 2>/dev/null || true)
[ -n "$DATA" ] && aws s3 rm "s3://$DATA" --recursive || true
[ -n "$RES" ] && aws s3 rm "s3://$RES" --recursive || true

terraform destroy -auto-approve || true

# Extra nudge for Lambda-in-VPC variant:
aws ec2 describe-network-interfaces \
  --filters Name=description,Values="AWS Lambda VPC ENI*" \
  --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null \
  | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id || true

terraform destroy -auto-approve || true
popd >/dev/null
echo "Cleanup attempted. Verify in console that no stragglers remain."
