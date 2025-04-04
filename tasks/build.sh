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

cp -r broker-config/. broker-config-built

if [ -d "terraform-yaml" ]; then
ACCESS_KEY_ID=$(grep 's3_broker_user_access_key_id_curr' "terraform-yaml/state.yml" | awk '{print $2}')
SECRET_ACCESS_KEY=$(grep 's3_broker_user_secret_access_key_curr' "terraform-yaml/state.yml" | awk '{print $2}')

cat << EOF > broker-config-built/vars.yml
access_key_id: $ACCESS_KEY_ID
secret_access_key: $SECRET_ACCESS_KEY
EOF
fi

# if a the config-template has the variable $INTERNAL_VPCE_ID
# in it then replace with passed in envar value $INTERNAL_VPCE_ID

regex="s/\$INTERNAL_VPCE_ID/${INTERNAL_VPCE_ID:-}/"
sed $regex broker-config/"${CONFIG_FILE_NAME}".yml > "${CONFIG_FILE_NAME}-rendered".yml

spruce merge "${CONFIG_FILE_NAME}-rendered".yml credentials.yml \
  > broker-config-built/config.yml
