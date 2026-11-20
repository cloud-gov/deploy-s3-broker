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

cleanup() {
  set +e
  cf delete-service-key -f "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME"
  cf delete-service-key -f "$SERVICE_INSTANCE_NAME" "$RW_KEY_NAME"
  cf delete-service -f "$SERVICE_INSTANCE_NAME"
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

rw_bucket=$(echo "$rw_creds" | jq -r '.bucket')
rw_access_key_id=$(echo "$rw_creds" | jq -r '.access_key_id')
rw_secret_access_key=$(echo "$rw_creds" | jq -r '.secret_access_key')
region=$(echo "$rw_creds" | jq -r '.region')

AWS_ACCESS_KEY_ID="$rw_access_key_id" AWS_SECRET_ACCESS_KEY="$rw_secret_access_key" \
  aws s3api put-object \
    --bucket "$rw_bucket" \
    --key "$TEST_OBJECT_KEY" \
    --body <(printf '%s' "$TEST_OBJECT_BODY") \
    --region "$region"

# Read-only key: the one under test.
cf create-service-key "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME" -c '{"read_only": true}'
ro_creds=$(cf service-key "$SERVICE_INSTANCE_NAME" "$RO_KEY_NAME" | sed -n '/^{/,$p')

ro_bucket=$(echo "$ro_creds" | jq -r '.bucket')
ro_access_key_id=$(echo "$ro_creds" | jq -r '.access_key_id')
ro_secret_access_key=$(echo "$ro_creds" | jq -r '.secret_access_key')
ro_read_only=$(echo "$ro_creds" | jq -r '.read_only')

if [ "$ro_read_only" != "true" ]; then
  echo "FAIL: expected credentials.read_only to be true, got: $ro_read_only"
  exit 1
fi

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
      --body <(printf '%s' "should not be writable") \
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

# Clean up the test object using the read/write key (cleanup trap handles CF resources).
AWS_ACCESS_KEY_ID="$rw_access_key_id" AWS_SECRET_ACCESS_KEY="$rw_secret_access_key" \
  aws s3api delete-object \
    --bucket "$rw_bucket" \
    --key "$TEST_OBJECT_KEY" \
    --region "$region"

echo "PASS: read-only smoke test completed successfully"
