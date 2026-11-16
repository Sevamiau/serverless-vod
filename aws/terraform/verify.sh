#!/usr/bin/env bash
# Post-apply checks for the default workspace.
set -uo pipefail
cd "$(dirname "$0")"

WORKSPACE=$(terraform workspace show)
if [ "$WORKSPACE" = "cliente" ]; then
    echo "Refusing to run against the cliente workspace: this seeds fake rows into real client tables." >&2
    exit 1
fi
export AWS_PROFILE=default
export AWS_REGION=sa-east-1

REGION="sa-east-1"
pass=0
fail=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  OK   %-55s (%s)\n' "$desc" "$actual"
        pass=$((pass + 1))
    else
        printf '  FAIL %-55s expected %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

sha256() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

DOMAIN=$(terraform output -raw site_domain)
SITE_BUCKET=$(terraform output -raw site_bucket_name)
MOVIE_BUCKET=$(terraform output -raw movie_bucket_name)
COOKIES=$(mktemp)

echo "Mercado Pago credentials:"
for name in mp-access-token mp-webhook-secret; do
    value=$(aws ssm get-parameter --name "/serverless-vod/$name" --with-decryption \
        --query Parameter.Value --output text 2>/dev/null || true)
    if [ -z "$value" ] || [ "$value" = "REPLACE_ME" ]; then
        state=placeholder
    elif [ "$value" != "$(printf '%s' "$value" | tr -cd '[:print:]')" ]; then
        state=control-chars
    else
        state=ok
    fi
    check "SSM $name is set and clean" ok "$state"
    if [ "$name" = mp-access-token ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $value" https://api.mercadopago.com/users/me)
        check "Mercado Pago accepts the access token" 200 "$code"
    fi
done
unset value
echo

BUYER_EMAIL="verify-buyer@example.com"
BUYER_TOKEN="verify-buyer-token"
NOBODY_TOKEN="verify-nobody-token"
DEVICE_IDS=(verify-device-01 verify-device-02 verify-device-03 verify-device-04 verify-device-05)

cleanup() {
    rm -f "$COOKIES"
    aws dynamodb delete-item --table-name svod-sessions \
        --key '{"tokenHash": {"S": "'"$(sha256 "$BUYER_TOKEN")"'"}}' >/dev/null 2>&1
    aws dynamodb delete-item --table-name svod-sessions \
        --key '{"tokenHash": {"S": "'"$(sha256 "$NOBODY_TOKEN")"'"}}' >/dev/null 2>&1
    aws dynamodb delete-item --table-name svod-entitlements \
        --key '{"userEmail": {"S": "'"$BUYER_EMAIL"'"}, "productId": {"S": "film01"}}' >/dev/null 2>&1
    for id in "${DEVICE_IDS[@]}"; do
        aws dynamodb delete-item --table-name svod-devices \
            --key '{"userEmail": {"S": "'"$BUYER_EMAIL"'"}, "deviceHash": {"S": "'"$(sha256 "$id")"'"}}' >/dev/null 2>&1
    done
}
trap cleanup EXIT

call_playback_token() {
    local cookie="$1" device_id="$2" label="$3" jar="${4:-}"
    local body="{\"deviceId\":\"$device_id\",\"label\":\"$label\"}"
    local args=(-s -o /dev/null -w '%{http_code}' -X POST "https://$DOMAIN/api/playback-token"
        -H "Content-Type: application/json"
        -H "x-amz-content-sha256: $(sha256 "$body")"
        -d "$body")
    [ -n "$cookie" ] && args+=(-H "Cookie: poc_session=$cookie")
    [ -n "$jar" ] && args+=(-c "$jar")
    curl "${args[@]}"
}

echo "Testing distribution: $DOMAIN"
echo

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")
check "site via CloudFront" 200 "$code"

headers=$(curl -s -o /dev/null -D - "https://$DOMAIN/ver.html" | tr -d "\r" | tr "[:upper:]" "[:lower:]")
check "security headers on pages" yes "$(grep -q "^strict-transport-security:" <<<"$headers" && grep -q "^content-security-policy:" <<<"$headers" && echo yes || echo no)"

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$SITE_BUCKET.s3.$REGION.amazonaws.com/index.html")
check "site bucket direct (should be blocked)" 403 "$code"

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/movie/film01/master.m3u8")
check "movie manifest, no cookies" 403 "$code"

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$MOVIE_BUCKET.s3.$REGION.amazonaws.com/movie/film01/master.m3u8")
check "movie bucket direct (should be blocked)" 403 "$code"

aws dynamodb put-item --table-name svod-sessions --item '{
  "tokenHash": {"S": "'"$(sha256 "$BUYER_TOKEN")"'"},
  "userEmail": {"S": "'"$BUYER_EMAIL"'"},
  "expiresAt": {"N": "'"$(($(date +%s) + 3600))"'"}
}' >/dev/null

aws dynamodb put-item --table-name svod-entitlements --item '{
  "userEmail": {"S": "'"$BUYER_EMAIL"'"},
  "productId": {"S": "film01"},
  "traceCode": {"S": "VERIFY1"}
}' >/dev/null

aws dynamodb put-item --table-name svod-sessions --item '{
  "tokenHash": {"S": "'"$(sha256 "$NOBODY_TOKEN")"'"},
  "userEmail": {"S": "nobody@example.com"},
  "expiresAt": {"N": "'"$(($(date +%s) + 3600))"'"}
}' >/dev/null

code=$(call_playback_token "" "verify-device-01" "laptop")
check "playback-token: no session cookie" 401 "$code"

code=$(call_playback_token "$NOBODY_TOKEN" "verify-device-99" "laptop")
check "playback-token: no entitlement" 403 "$code"

mint_code=$(call_playback_token "$BUYER_TOKEN" "verify-device-01" "laptop" "$COOKIES")
check "playback-token: valid session + entitlement" 200 "$mint_code"

code=$(call_playback_token "$BUYER_TOKEN" "verify-device-02" "phone")
check "playback-token: concurrency (second device too soon)" 403 "$code"

for n in 03 04; do
    aws dynamodb put-item --table-name svod-devices --item '{
    "userEmail": {"S": "'"$BUYER_EMAIL"'"},
    "deviceHash": {"S": "'"$(sha256 "verify-device-$n")"'"},
    "label": {"S": "seeded"},
    "firstSeen": {"N": "'"$(date +%s)"'"},
    "lastSeen": {"N": "'"$(date +%s)"'"}
  }' >/dev/null
done

code=$(call_playback_token "$BUYER_TOKEN" "verify-device-05" "tablet")
check "playback-token: device cap (3/3)" 403 "$code"

code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIES" -H "Referer: https://$DOMAIN/" "https://$DOMAIN/movie/film01/master.m3u8")
check "movie manifest, valid cookies + correct referer" 200 "$code"

code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIES" -H "Referer: https://evil.example.com/" "https://$DOMAIN/movie/film01/master.m3u8")
check "movie manifest, valid cookies + wrong referer" 403 "$code"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
