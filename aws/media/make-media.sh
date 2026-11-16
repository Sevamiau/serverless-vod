#!/usr/bin/env bash
# Encodes source.mp4 (or test color bars) to HLS in ./movie/.
# Optional subtitles: subs/<lang>.srt or .vtt
set -euo pipefail
cd "$(dirname "$0")"
OUT=movie
SUBS_IN=subs
FF=ffmpeg
FP=ffprobe
if ! command -v ffmpeg >/dev/null 2>&1; then
  FF="podman run --rm -v $PWD:/w -w /w docker.io/linuxserver/ffmpeg"
  FP="podman run --rm -v $PWD:/w -w /w --entrypoint ffprobe docker.io/linuxserver/ffmpeg"
fi

rm -rf "$OUT"

# height, video, maxrate, bufsize
LADDER=(
  "1080 5000k 5350k 10000k"
  "720  2800k 3000k 5600k"
  "480  1400k 1500k 2800k"
  "360  800k  856k  1600k"
)

if [ -f source.mp4 ]; then
  IN=(-i source.mp4)
  AUDIO=0:a:0
  DUR=$($FP -v error -show_entries format=duration -of csv=p=0 source.mp4 | cut -d. -f1)
  SRC_H=$($FP -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 source.mp4)
  echo "-> encoding source.mp4 (${DUR}s, ${SRC_H}p)"
else
  DUR="${DUR:-120}"
  IN=(-f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=$DUR"
      -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=$DUR")
  AUDIO=1:a
  SRC_H=1080
  echo "-> no source.mp4: generating color bars (${DUR}s)"
fi

# no upscaling
RUNGS=()
for r in "${LADDER[@]}"; do
  read -r h _ <<<"$r"
  [ "$h" -le "$SRC_H" ] && RUNGS+=("$r")
done
[ ${#RUNGS[@]} -gt 0 ] || RUNGS=("${LADDER[-1]}")

N=${#RUNGS[@]}
FILTER="[0:v]split=$N"
for i in $(seq 0 $((N - 1))); do FILTER+="[s$i]"; done
MAPS=(); RATES=(); STREAMS=(); LABELS=()
for i in $(seq 0 $((N - 1))); do
  read -r h vb maxr buf <<<"${RUNGS[$i]}"
  FILTER+=";[s$i]scale=-2:$h[o$i]"
  MAPS+=(-map "[o$i]" -map "$AUDIO")
  RATES+=(-b:v:$i "$vb" -maxrate:v:$i "$maxr" -bufsize:v:$i "$buf")
  STREAMS+=("v:$i,a:$i")
  LABELS+=("${h}p")
  mkdir -p "$OUT/$i"
done

$FF -y -loglevel error "${IN[@]}" \
  -filter_complex "$FILTER" "${MAPS[@]}" \
  -c:v libx264 -preset veryfast -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -ac 2 "${RATES[@]}" \
  -f hls -hls_time 4 -hls_playlist_type vod -hls_list_size 0 \
  -hls_segment_filename "$OUT/%v/seg%04d.ts" \
  -var_stream_map "${STREAMS[*]}" -master_pl_name master.m3u8 \
  "$OUT/%v/index.m3u8"

shopt -s nullglob
SUBS=("$SUBS_IN"/*.srt "$SUBS_IN"/*.vtt)
SAMPLE=""
if [ ${#SUBS[@]} -eq 0 ] && [ ! -f source.mp4 ]; then
  SAMPLE=_subs_sample
  mkdir -p "$SAMPLE"
  {
    echo "WEBVTT"
    for t in $(seq 0 10 $((DUR - 10))); do
      printf '\n%02d:%02d.000 --> %02d:%02d.000\nSubtítulo de prueba, segundo %d\n' \
        $((t / 60)) $((t % 60)) $(((t + 5) / 60)) $(((t + 5) % 60)) "$t"
    done
  } >"$SAMPLE/es.vtt"
  SUBS=("$SAMPLE/es.vtt")
fi

SUB_LABELS=()
if [ ${#SUBS[@]} -gt 0 ]; then
  # .ts segments don't start at 0
  START=$($FP -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$OUT/0/seg0000.ts")
  MPEGTS=$(awk -v s="$START" 'BEGIN { printf "%d", s * 90000 + 0.5 }')
  MEDIA=""
  for f in "${SUBS[@]}"; do
    lang=$(basename "${f%.*}")
    case "$lang" in
      es) name="Español" ;; en) name="English" ;; pt) name="Português" ;;
      fr) name="Français" ;; it) name="Italiano" ;; de) name="Deutsch" ;;
      *) name="$lang" ;;
    esac
    mkdir -p "$OUT/subs/$lang"
    $FF -y -loglevel error -i "$f" "$OUT/subs/$lang/full.vtt"
    sed -i "1a X-TIMESTAMP-MAP=MPEGTS:$MPEGTS,LOCAL:00:00:00.000" "$OUT/subs/$lang/full.vtt"
    cat >"$OUT/subs/$lang/index.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:$((DUR + 1))
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:$DUR.000,
full.vtt
#EXT-X-ENDLIST
EOF
    MEDIA+="#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"$name\",LANGUAGE=\"$lang\",DEFAULT=NO,AUTOSELECT=YES,URI=\"subs/$lang/index.m3u8\""$'\n'
    SUB_LABELS+=("$lang")
  done
  awk -v media="$MEDIA" '
    /^#EXT-X-STREAM-INF:/ && !done { printf "%s", media; done = 1 }
    /^#EXT-X-STREAM-INF:/ { $0 = $0 ",SUBTITLES=\"subs\"" }
    { print }
  ' "$OUT/master.m3u8" >"$OUT/master.tmp" && mv "$OUT/master.tmp" "$OUT/master.m3u8"
fi
[ -n "$SAMPLE" ] && rm -rf "$SAMPLE"

echo "OK -> $OUT · ${LABELS[*]} · subtitles: ${SUB_LABELS[*]:-none}$([ -n "$SAMPLE" ] && echo ' (sample)') · $(find "$OUT" -name '*.ts' | wc -l) segments · $(du -sh "$OUT" | cut -f1) · ${DUR}s"
