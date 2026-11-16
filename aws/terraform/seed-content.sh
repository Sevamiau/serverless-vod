#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

MEDIA_DIR="${MEDIA_DIR:-../media/movie}"

WORKSPACE=$(terraform workspace show)
if [ "$WORKSPACE" = "cliente" ]; then
    export AWS_PROFILE=cliente
else
    export AWS_PROFILE=default
fi
export AWS_REGION=sa-east-1

SITE_BUCKET=$(terraform output -raw site_bucket_name)
MOVIE_BUCKET=$(terraform output -raw movie_bucket_name)
DISTRIBUTION_ID=$(terraform output -raw distribution_id)

echo "Workspace:    $WORKSPACE (profile $AWS_PROFILE)"
echo "Site bucket:  $SITE_BUCKET"
echo "Movie bucket: $MOVIE_BUCKET"
echo

REVALIDATE="no-cache"
YEAR="public, max-age=31536000, immutable"
DAY="public, max-age=86400"

# cp, not sync: sync skips unchanged files, which would keep their old headers
echo "-> site (../site/)"
aws s3 cp ../site/ "s3://$SITE_BUCKET/" --recursive --only-show-errors \
    --exclude "*.woff2" --cache-control "$REVALIDATE"
aws s3 cp ../site/ "s3://$SITE_BUCKET/" --recursive --only-show-errors \
    --exclude "*" --include "*.woff2" --content-type font/woff2 --cache-control "$YEAR"
aws s3 sync ../site/ "s3://$SITE_BUCKET/" --delete --only-show-errors

if [ -d "$MEDIA_DIR" ]; then
    echo "-> movie/film01/ (from $MEDIA_DIR)"
    DEST="s3://$MOVIE_BUCKET/movie/film01/"
    # segments keep their names across re-encodes, so not a year
    aws s3 sync "$MEDIA_DIR/" "$DEST" --only-show-errors \
        --exclude "*.m3u8" --exclude "*.vtt" --cache-control "$DAY"
    aws s3 cp "$MEDIA_DIR/" "$DEST" --recursive --only-show-errors \
        --exclude "*" --include "*.m3u8" --content-type application/vnd.apple.mpegurl --cache-control "$REVALIDATE"
    aws s3 cp "$MEDIA_DIR/" "$DEST" --recursive --only-show-errors \
        --exclude "*" --include "*.vtt" --content-type text/vtt --cache-control "$REVALIDATE"
else
    echo "-> skipping movie/: $MEDIA_DIR not found (run ../media/make-media.sh first, or set MEDIA_DIR)"
fi

echo "-> invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths '/*' --query 'Invalidation.Id' --output text

echo
echo "done"
