#!/usr/bin/env bash
# Baut aus einem Quell-Reel mehrere Varianten (Hook-Text, Zoom, Farbton, Schnittbeginn)
# und legt sie auf der gh-pages-Branche ab (oeffentliche Video-URLs fuer die Instagram-API).
set -euo pipefail

: "${SOURCE_URL:?}" "${BATCH_ID:?}" "${HOOKS:?}" "${GITHUB_TOKEN:?}"
WORK=$(mktemp -d)
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
OWNER=$(echo "${GITHUB_REPOSITORY_OWNER}" | tr 'A-Z' 'a-z')
REPO="${GITHUB_REPOSITORY#*/}"
REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

curl -fsSL --retry 3 -o "$WORK/source.mp4" "$SOURCE_URL"
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$WORK/source.mp4")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$WORK/source.mp4")

if git clone --quiet --depth 1 --branch gh-pages "$REMOTE" pages 2>/dev/null; then
  echo "gh-pages vorhanden"
else
  mkdir pages
  git -C pages init -q -b gh-pages
  git -C pages remote add origin "$REMOTE"
fi
mkdir -p "pages/out/$BATCH_ID"
touch pages/.nojekyll

# Alte Batches (aelter als 3 Tage, Datum steht vorn im Batch-Namen) entfernen
CUTOFF=$(date -u -d '3 days ago' +%Y%m%d)
for d in pages/out/*; do
  b=$(basename "$d")
  case "$b" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) [ "${b:0:8}" -lt "$CUTOFF" ] && rm -rf "$d" || true ;; esac
done

IFS='|' read -r -a HOOK_LIST <<< "$HOOKS"
i=0
: > "$WORK/items.jsonl"
for RAW in "${HOOK_LIST[@]}"; do
  HOOK=$(echo "$RAW" | sed 's/^ *//;s/ *$//')
  [ -z "$HOOK" ] && continue
  i=$((i+1))
  N=$(printf '%02d' "$i")
  SS=$(awk -v i="$i" 'BEGIN{printf "%.2f", ((i-1)%4)*0.35}')
  ZOOM=$(awk -v i="$i" 'BEGIN{printf "%.3f", 1.03+((i*7)%6)*0.012}')
  BRI=$(awk -v i="$i" 'BEGIN{printf "%.3f", (((i*5)%7)-3)*0.012}')
  SAT=$(awk -v i="$i" 'BEGIN{printf "%.3f", 1.0+(((i*3)%7)-3)*0.04}')
  HUE=$(awk -v i="$i" 'BEGIN{printf "%.1f", (((i*11)%9)-4)*1.5}')
  YPOS=$(awk -v i="$i" 'BEGIN{printf "%d", 12+((i*13)%5)*3}')
  CW=$(awk -v w="$W" -v z="$ZOOM" 'BEGIN{printf "%d", int(w/z/2)*2}')
  CH=$(awk -v h="$H" -v z="$ZOOM" 'BEGIN{printf "%d", int(h/z/2)*2}')
  echo "$HOOK" | fold -s -w 24 > "$WORK/hook.txt"
  VF="crop=$CW:$CH,scale=$W:$H:flags=lanczos,eq=brightness=$BRI:saturation=$SAT,hue=h=$HUE,drawtext=fontfile=$FONT:textfile=$WORK/hook.txt:fontcolor=white:fontsize=h/26:line_spacing=10:box=1:boxcolor=black@0.45:boxborderw=18:x=(w-text_w)/2:y=h*$YPOS/100:enable='lt(t,3.2)'"
  ffmpeg -y -loglevel error -ss "$SS" -i "$WORK/source.mp4" -vf "$VF" -map 0:v -map '0:a?' \
    -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart -t 90 \
    "pages/out/$BATCH_ID/v$N.mp4"
  jq -n --arg id "v$N" --arg hook "$HOOK" --arg url "https://$OWNER.github.io/$REPO/out/$BATCH_ID/v$N.mp4" \
    '{id:$id,hook:$hook,url:$url}' >> "$WORK/items.jsonl"
  echo "Variante $N fertig"
done

jq -s --arg batch "$BATCH_ID" '{batch:$batch,variants:.}' "$WORK/items.jsonl" > "pages/out/$BATCH_ID/manifest.json"

cd pages
git config user.name "reel-lab"
git config user.email "actions@users.noreply.github.com"
git checkout -q --orphan tmp 2>/dev/null || git checkout -q -b tmp
git add -A
git commit -q -m "batch $BATCH_ID"
git push -q -f origin tmp:gh-pages
echo "Fertig: $i Varianten"
