#!/bin/bash

set -e
set -u

cat << EOF > credentials.yml
username: "${AUTH_USERNAME}"
password: "${AUTH_PASSWORD}"
environment: "${ENVIRONMENT}"
s3_config:
  region: "${AWS_REGION}"
  aws_partition: "${AWS_PARTITION}"
  user_prefix: "${USER_PREFIX}"
  policy_prefix: "${POLICY_PREFIX}"
  bucket_prefix: "${BUCKET_PREFIX}"
  iam_path: "${IAM_PATH}"
cf_config:
  api_url: "${CF_API_URL}"
  client_id: "${CF_CLIENT_ID}"
  client_secret: "${CF_CLIENT_SECRET}"
EOF

cp -r broker-src-dev/. broker-src-built

ACCESS_KEY_ID=$(grep 's3_broker_user_access_key_id_curr' "$TF_RESOURCE_NAME/state.yml" | awk '{print $2}')
SECRET_ACCESS_KEY=$(grep 's3_broker_user_secret_access_key_curr' "$TF_RESOURCE_NAME/state.yml" | awk '{print $2}')

# Override upstream example manifest
cat << EOF > broker-src-built/manifest.yml
applications:
- name: s3-broker
  memory: 256M
  disk_quota: 256M
  buildpack: go_buildpack
  command: s3-broker --config ./config.yml --port \$PORT
env:
  GOPACKAGENAME: github.com/cloud-gov/s3-broker
  AWS_ACCESS_KEY: $ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY: $SECRET_ACCESS_KEY
EOF

# if a the config-template has the variable $INTERNAL_VPCE_ID
# in it then replace with passed in envar value $INTERNAL_VPCE_ID

regex="s/\$INTERNAL_VPCE_ID/${INTERNAL_VPCE_ID:-}/"
sed $regex broker-config-dev/"${CONFIG_FILE_NAME}".yml > "${CONFIG_FILE_NAME}-rendered".yml

spruce merge "${CONFIG_FILE_NAME}-rendered".yml credentials.yml \
  > broker-src-built/config.yml
