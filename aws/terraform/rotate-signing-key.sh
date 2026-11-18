#!/usr/bin/env bash
# New CloudFront signing key pair into SSM. Run before `terraform apply`.
set -euo pipefail
cd "$(dirname "$0")"

WORKSPACE=$(terraform workspace show)
if [ "$WORKSPACE" = "cliente" ]; then
    export AWS_PROFILE=cliente
else
    export AWS_PROFILE=default
fi
export AWS_REGION=sa-east-1
echo "Workspace: $WORKSPACE (profile $AWS_PROFILE)"

umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl rsa -in "$TMP/key.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null

aws ssm put-parameter --name /serverless-vod/movie-signing-key --type SecureString --overwrite \
    --value "file://$TMP/key.pem" >/dev/null
aws ssm put-parameter --name /serverless-vod/movie-signing-key-public --type String --overwrite \
    --value "file://$TMP/pub.pem" >/dev/null

echo "Key pair stored in SSM. Now: terraform apply"
