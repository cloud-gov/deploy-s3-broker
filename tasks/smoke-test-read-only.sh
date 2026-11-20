#!/bin/bash
#
# Smoke test for read-only service key bindings.
#
# Creates an S3 service instance, writes an object to it using a normal
# (read/write) service key, then creates a read-only service key
# (`read_only: true` bind parameter) and verifies that it:
#   - can read the object written above
#   - cannot write a new object
#   - cannot delete the existing object
#
# Cleans up all created CF resources and the test object on exit.

set -eu

SERVICE_NAME="${SERVICE_NAME:?Must set SERVICE_NAME}"
PLAN_NAME="${PLAN_NAME:?Must set PLAN_NAME}"
SERVICE_INSTANCE_NAME="${SERVICE_INSTANCE_NAME:?Must set SERVICE_INSTANCE_NAME}"

RW_KEY_NAME="${SERVICE_INSTANCE_NAME}-rw-key"
RO_KEY_NAME="${SERVICE_INSTANCE_NAME}-read-only-key"
TEST_OBJECT_KEY="smoke-test-read-only-object"
TEST_OBJECT_BODY="smoke-test-read-only-body"

WORKDIR=$(mktemp -d)
TEST_OBJECT_FILE="${WORKDIR}/test-object-body"
WRITE_ATTEMPT_FILE="${WORKDIR}/write-attempt-body"
printf '%s' "$TEST_OBJECT_BODY" > "$TEST_OBJECT_FILE"
printf '%s' "should not be writable" > "$WRITE_ATTEMPT_FILE"

empty_bucket() {
  local bucket="$1" access_key="$2" secret_key="$3" bucket_region="$4"

  AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" \
    aws s3 rm "s3://${bucket}" --recursive --region "$bucket_region"

  while :; do
    versions_json=$(AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" \
      aws s3api list-object-versions \
        --bucket "$bucket" \
        --region "$bucket_region" \
        --max-items 1000 \
        --output json) || break

    delete_payload=$(echo "$versions_json" | jq -c '{
      Objects: ((.Versions // []) + (.DeleteMarkers // []) | map({Key: .Key, VersionId: .VersionId})),
      Quiet: true
    }')

    object_count=$(echo "$delete_payload" | jq '.Objects | length')
    if [ "$object_count" -eq 0 ]; then
      break
    fi

    AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" \
      aws s3api delete-objects \
        --bucket "$bucket" \
        --region "$bucket_region" \
        --delete "$delete_payload" >/dev/null
  done
}

wait_for_credentials() {
  local access_key="$1" secret_key="$2" bucket="$3" bucket_region="$4"
  local max_attempts=15
  local attempt=1

  local transient_error_pattern="InvalidAccessKeyId|SignatureDoesNotMatch"

  while [ "$attempt" -le "$max_attempts" ]; do
    if AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" \
        aws s3api list-objects-v2 --bucket "$bucket" --max-items 1 --region "$bucket_region" >/dev/null 2>/tmp/wait-for-credentials-error.log; then
      return 0
    fi
    if ! grep -qiE "$transient_error_pattern" /tmp/wait-for-credentials-error.log; then
      cat /tmp/wait-for-credentials-error.log
      return 1
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "FAIL: access key $access_key did not become usable after $max_attempts attempts"
  cat /tmp/wait-for-credentials-error.log
  return 1
}

# Populated once the read/write service key is created; used by cleanup to
# empty the bucket so `cf delete-service` (which does not empty non-empty
# buckets unless the plan is configured as deletable) does not fail.
rw_bucket=""
rw_access_key_id=""
rw_secret_access_key=""
region=""

cleanup() {
  set +e
  # S3 buckets must be empty before they can be deleted; empty it with the
  # read/write key (if we got that far) before deleting the service.
  if [ -n "$rw_bucket" ] && [ -n "$rw_access_key_id" ] && [ -n "$rw_secret_access_key" ]; then
    empty_bucket "$rw_bucket" "$rw_access_key_id" "$rw_secret_access_key" "$region"
  fi
  cf delete-service-key -f "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME"
  cf delete-service-key -f "$SERVICE_INSTANCE_NAME" "$RW_KEY_NAME"
  cf delete-service -f "$SERVICE_INSTANCE_NAME"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

cf api "${CF_API_URL}"
(set +x; cf auth "$CF_USERNAME" "$CF_PASSWORD")
cf target -o "$CF_ORGANIZATION"
cf target -s "$CF_SPACE"

cf create-service "$SERVICE_NAME" "$PLAN_NAME" "$SERVICE_INSTANCE_NAME"

# Read/write key: used to seed the object the read-only key will read.
cf create-service-key "$SERVICE_INSTANCE_NAME" "$RW_KEY_NAME"
rw_creds=$(cf service-key "$SERVICE_INSTANCE_NAME" "$RW_KEY_NAME" | sed -n '/^{/,$p')

rw_bucket=$(echo "$rw_creds" | jq -r '.credentials.bucket')
rw_access_key_id=$(echo "$rw_creds" | jq -r '.credentials.access_key_id')
rw_secret_access_key=$(echo "$rw_creds" | jq -r '.credentials.secret_access_key')
region=$(echo "$rw_creds" | jq -r '.credentials.region')

for name_value in "bucket:$rw_bucket" "access_key_id:$rw_access_key_id" "secret_access_key:$rw_secret_access_key" "region:$region"; do
  field="${name_value%%:*}"
  value="${name_value#*:}"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "FAIL: could not parse credentials.$field from read/write service key. Full output:"
    echo "$rw_creds"
    exit 1
  fi
done

wait_for_credentials "$rw_access_key_id" "$rw_secret_access_key" "$rw_bucket" "$region"

AWS_ACCESS_KEY_ID="$rw_access_key_id" AWS_SECRET_ACCESS_KEY="$rw_secret_access_key" \
  aws s3api put-object \
    --bucket "$rw_bucket" \
    --key "$TEST_OBJECT_KEY" \
    --body "$TEST_OBJECT_FILE" \
    --region "$region"

# Read-only key: the one under test.
cf create-service-key "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME" -c '{"read_only": true}'
ro_creds=$(cf service-key "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME" | sed -n '/^{/,$p')

ro_bucket=$(echo "$ro_creds" | jq -r '.credentials.bucket')
ro_access_key_id=$(echo "$ro_creds" | jq -r '.credentials.access_key_id')
ro_secret_access_key=$(echo "$ro_creds" | jq -r '.credentials.secret_access_key')
ro_read_only=$(echo "$ro_creds" | jq -r '.credentials.read_only')

for name_value in "bucket:$ro_bucket" "access_key_id:$ro_access_key_id" "secret_access_key:$ro_secret_access_key"; do
  field="${name_value%%:*}"
  value="${name_value#*:}"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "FAIL: could not parse credentials.$field from read-only service key. Full output:"
    echo "$ro_creds"
    exit 1
  fi
done

if [ "$ro_read_only" != "true" ]; then
  echo "FAIL: expected credentials.read_only to be true, got: $ro_read_only"
  exit 1
fi

wait_for_credentials "$ro_access_key_id" "$ro_secret_access_key" "$ro_bucket" "$region"

# Read-only key must be able to read the object.
actual_body=$(
  AWS_ACCESS_KEY_ID="$ro_access_key_id" AWS_SECRET_ACCESS_KEY="$ro_secret_access_key" \
    aws s3api get-object \
      --bucket "$ro_bucket" \
      --key "$TEST_OBJECT_KEY" \
      --region "$region" \
      /dev/stdout
)
if [ "$actual_body" != "$TEST_OBJECT_BODY" ]; then
  echo "FAIL: read-only key could not read expected object contents. got: $actual_body"
  exit 1
fi
echo "PASS: read-only key can read objects"

# Read-only key must NOT be able to write a new object.
if AWS_ACCESS_KEY_ID="$ro_access_key_id" AWS_SECRET_ACCESS_KEY="$ro_secret_access_key" \
    aws s3api put-object \
      --bucket "$ro_bucket" \
      --key "${TEST_OBJECT_KEY}-write-attempt" \
      --body "$WRITE_ATTEMPT_FILE" \
      --region "$region" 2>/tmp/put-object-error.log; then
  echo "FAIL: read-only key was able to write an object; it should have been denied"
  exit 1
fi
if ! grep -qi "AccessDenied" /tmp/put-object-error.log; then
  echo "FAIL: expected AccessDenied error when writing with read-only key, got:"
  cat /tmp/put-object-error.log
  exit 1
fi
echo "PASS: read-only key is denied write access"

# Read-only key must NOT be able to delete the existing object.
if AWS_ACCESS_KEY_ID="$ro_access_key_id" AWS_SECRET_ACCESS_KEY="$ro_secret_access_key" \
    aws s3api delete-object \
      --bucket "$ro_bucket" \
      --key "$TEST_OBJECT_KEY" \
      --region "$region" 2>/tmp/delete-object-error.log; then
  echo "FAIL: read-only key was able to delete an object; it should have been denied"
  exit 1
fi
if ! grep -qi "AccessDenied" /tmp/delete-object-error.log; then
  echo "FAIL: expected AccessDenied error when deleting with read-only key, got:"
  cat /tmp/delete-object-error.log
  exit 1
fi
echo "PASS: read-only key is denied delete access"

echo "PASS: read-only smoke test completed successfully"
