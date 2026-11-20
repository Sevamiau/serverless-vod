#!/usr/bin/env bash
# Landing background loop from source.mp4 into ../site/media/.
# START/DUR in seconds; default is the road shot (3:19, 14 s).
set -euo pipefail
cd "$(dirname "$0")"
START="${START:-199}"
DUR="${DUR:-14}"
CROP="${CROP:-1920:800:0:140}" # master is letterboxed 2.39:1
X=1.5 # the end crossfades into the start, so the loop has no seam
OUT=../site/media
mkdir -p "$OUT"

TOTAL=$(awk -v d="$DUR" -v x="$X" 'BEGIN { print d + x }')
OFF=$(awk -v d="$DUR" -v x="$X" 'BEGIN { print d - x }')
enc() {
  ffmpeg -v error -y -ss "$START" -t "$TOTAL" -i source.mp4 -an -filter_complex "
    [0:v]crop=$CROP,scale=$1:-2,setsar=1,split[a][b];
    [a]trim=$X:$TOTAL,setpts=PTS-STARTPTS,fps=25[body];
    [b]trim=0:$X,setpts=PTS-STARTPTS,fps=25[head];
    [body][head]xfade=transition=fade:duration=$X:offset=$OFF,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -preset slow -crf "$2" -profile:v high -movflags +faststart "$OUT/$3"
}
enc 1920 24 hero.mp4
enc 960 25 hero-sm.mp4
ffmpeg -v error -y -i "$OUT/hero.mp4" -frames:v 1 -q:v 4 "$OUT/hero.jpg"

ls -la "$OUT"
