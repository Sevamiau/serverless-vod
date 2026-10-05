#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")"

MEDIA_DIR="${MEDIA_DIR:-$HOME/work/peli/peli/media/movie}"

SITE_BUCKET=$(terraform output -raw site_bucket_name)
MOVIE_BUCKET=$(terraform output -raw movie_bucket_name)

echo "Site bucket:  $SITE_BUCKET"
echo "Movie bucket: $MOVIE_BUCKET"
echo

echo "-> index.html"
echo "hello from serverless-vod" >/tmp/index.html
aws s3 cp /tmp/index.html "s3://$SITE_BUCKET/index.html"

echo "-> ver.html"
aws s3 cp ../site/ver.html "s3://$SITE_BUCKET/ver.html"

echo "-> comprar.html"
aws s3 cp ../site/comprar.html "s3://$SITE_BUCKET/comprar.html"

echo "-> gracias.html"
aws s3 cp ../site/gracias.html "s3://$SITE_BUCKET/gracias.html"

if [ -d "$MEDIA_DIR" ]; then
    echo "-> movie/ (from $MEDIA_DIR)"
    aws s3 sync "$MEDIA_DIR/" "s3://$MOVIE_BUCKET/movie/"
else
    echo "-> skipping movie/: $MEDIA_DIR not found (run make-media.sh first, or set MEDIA_DIR)"
fi

echo
echo "done"
