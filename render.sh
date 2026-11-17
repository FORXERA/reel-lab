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

# Spracherkennung (einmal pro Quelle): mit Sprache bleibt nur der Originalton, ohne Sprache nur Musik
SPEECH=0
if ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$WORK/source.mp4" | grep -q audio; then
  if ffmpeg -y -loglevel error -i "$WORK/source.mp4" -vn -ac 1 -ar 16000 "$WORK/a.wav" && pip install -q --break-system-packages faster-whisper >"$WORK/pip.log" 2>&1; then
    WORDS=$(python3 - "$WORK/a.wav" <<'PY' 2>"$WORK/py.err" || echo -1
import sys, wave
import numpy as np
from faster_whisper import WhisperModel
m = WhisperModel("tiny", device="cpu", compute_type="int8")
w = wave.open(sys.argv[1])
aud = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768.0
segs, info = m.transcribe(aud, vad_filter=True)
print(sum(len(s.text.split()) for s in segs if s.no_speech_prob < 0.5))
PY
)
    if [ "${WORDS:--1}" -ge 3 ] || [ "${WORDS:--1}" -lt 0 ]; then SPEECH=1; fi
  else
    SPEECH=1
  fi
fi
tail -n 3 "$WORK/pip.log" 2>/dev/null || true; tail -n 6 "$WORK/py.err" 2>/dev/null || true
echo "Sprache erkannt: $SPEECH (Woerter: ${WORDS:-0})"

# Lizenzfreie Musik (Pixabay Content License); Download optional, ohne Musik bleibt der Originalton
mkdir -p "$WORK/mus"
k=0
for u in 2026/10/08/audio_05b3828b90 2026/07/29/audio_5065cf04e4 2026/10/10/audio_777101bd7e 2026/10/28/audio_b00b8dab00 2026/09/19/audio_296e4eb904 2026/11/12/audio_59da2cf69e 2026/08/04/audio_a07a6b2841 2026/11/05/audio_a8e61a4ad7 2026/08/20/audio_1ccdcf375d 2026/08/21/audio_48e2266529 2026/07/06/audio_c0a2721743 2026/10/19/audio_01cd203c4c; do
  k=$((k+1))
  curl -fsSL --retry 2 -m 60 -A "Mozilla/5.0" -e "https://pixabay.com/" -o "$WORK/mus/m$k.mp3" "https://cdn.pixabay.com/download/audio/$u.mp3" 2>/dev/null || rm -f "$WORK/mus/m$k.mp3"
done
MFILES=("$WORK"/mus/m*.mp3)
[ -e "${MFILES[0]}" ] || MFILES=()
echo "Musikdateien: ${#MFILES[@]}"
DAYN=$((10#$(date +%j)))

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
  case $((i % 6)) in
    0) LOOK="null";;
    1) LOOK="colorbalance=rs=.08:gs=.02:bs=-.08:rm=.06:bm=-.06";;
    2) LOOK="colorbalance=rs=-.06:bs=.08:rm=-.05:bm=.07";;
    3) LOOK="curves=preset=medium_contrast";;
    4) LOOK="eq=contrast=0.93:gamma=1.06";;
    5) LOOK="vignette=PI/5";;
  esac
  VF="crop=$CW:$CH,scale=$W:$H:flags=lanczos,eq=brightness=$BRI:saturation=$SAT,hue=h=$HUE,$LOOK,drawtext=fontfile=$FONT:textfile=$WORK/hook.txt:fontcolor=white:fontsize=h/26:line_spacing=10:box=1:boxcolor=black@0.45:boxborderw=18:x=(w-text_w)/2:y=h*$YPOS/100:enable='lt(t,3.2)'"
  MODE=hook
  SHOWHOOK=1
  if [[ "$BATCH_ID" == *frame* || ( "$BATCH_ID" == *-dorian-* && "${BATCH_ID:0:8}" -lt 20261116 ) ]]; then
    # bisheriges Verhalten (Dorian und Frame-Chargen)
    if [ "$i" -ge 6 ] && [ "$i" -le 9 ]; then MODE=plain; fi
    if [ "$i" -ge 10 ] || [[ "$BATCH_ID" == *frame* ]] || { [[ "$BATCH_ID" == *-dorian-* ]] && [ $((i % 2)) -eq 0 ]; }; then MODE=frame; fi
  else
    # Franco: Typen wechseln reihum - 1 Hook im Vollbild, 2 Rahmen mit Hook, 3 ohne Text, 4 Rahmen ohne Hook
    case $(( (i - 1) % 4 )) in
      0) MODE=hook;;
      1) MODE=frame;;
      2) MODE=plain;;
      3) MODE=frame; SHOWHOOK=0;;
    esac
  fi
  if [ "$MODE" = "frame" ]; then
    FW=$((560 + (i % 3) * 20))
    FC="[0:v]split[a][b];[a]scale=720:1280:force_original_aspect_ratio=increase,crop=720:1280,boxblur=28:4,eq=brightness=-0.18:saturation=1.1[bg];[b]crop=$CW:$CH,scale=$FW:-2,eq=brightness=$BRI:saturation=$SAT,$LOOK[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2+40"
    if [ "$SHOWHOOK" = 1 ]; then FC="$FC,drawtext=fontfile=$FONT:textfile=$WORK/hook.txt:fontcolor=white:fontsize=44:line_spacing=10:box=1:boxcolor=black@0.45:boxborderw=16:x=(w-text_w)/2:y=110:enable='lt(t,3.2')"; fi
    FC="$FC[o]"
    ffmpeg -y -loglevel error -ss "$SS" -i "$WORK/source.mp4" -filter_complex "$FC" -map '[o]' -map '0:a?' \
      -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart -t 90 \
      "pages/out/$BATCH_ID/v$N.mp4"
  else
    if [ "$MODE" = "plain" ]; then VF="${VF%%,drawtext=*}"; fi
    ffmpeg -y -loglevel error -ss "$SS" -i "$WORK/source.mp4" -vf "$VF" -map 0:v -map '0:a?' \
      -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart -t 90 \
      "pages/out/$BATCH_ID/v$N.mp4"
  fi
  AM=0
  if [ $((i % 5)) -eq 4 ] && [ "$SPEECH" = 0 ]; then AM=1; fi
  if [ "$AM" -ne 0 ] && [ "${#MFILES[@]}" -gt 0 ]; then
    MT="${MFILES[$(( (i + DAYN) % ${#MFILES[@]} ))]}"
    OUTF="pages/out/$BATCH_ID/v$N.mp4"
    if [ "$AM" -eq 1 ]; then
      ffmpeg -y -loglevel error -i "$OUTF" -stream_loop -1 -i "$MT" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k -af "volume=0.9" -shortest -movflags +faststart "$WORK/mix.mp4" && mv "$WORK/mix.mp4" "$OUTF" || true
    else
      ffmpeg -y -loglevel error -i "$OUTF" -stream_loop -1 -i "$MT" -filter_complex "[0:a]volume=0.5[a0];[1:a]volume=0.35[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=0[a]" -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 128k -shortest -movflags +faststart "$WORK/mix.mp4" && mv "$WORK/mix.mp4" "$OUTF" || true
    fi
  fi
  jq -n --arg id "v$N" --arg hook "$HOOK" --arg url "https://$OWNER.github.io/$REPO/out/$BATCH_ID/v$N.mp4" \
    '{id:$id,hook:$hook,url:$url}' >> "$WORK/items.jsonl"
  echo "Variante $N fertig"
done

jq -s --arg batch "$BATCH_ID" '{batch:$batch,variants:.}' "$WORK/items.jsonl" > "pages/out/$BATCH_ID/manifest.json"

# Veroeffentlichen: bei gleichzeitigen Laeufen den aktuellen gh-pages-Stand frisch holen,
# nur den eigenen Batch dazulegen und bei Konflikt (Ref-Lock) neu versuchen.
KEEP="$WORK/keep"
mkdir -p "$KEEP"
cp -r "pages/out/$BATCH_ID" "$KEEP/$BATCH_ID"
rm -rf pages
PUSHED=0
for TRY in 1 2 3 4 5 6 7 8; do
  rm -rf pages
  if git clone --quiet --depth 1 --branch gh-pages "$REMOTE" pages 2>/dev/null; then :; else
    mkdir pages
    git -C pages init -q -b gh-pages
    git -C pages remote add origin "$REMOTE"
  fi
  mkdir -p pages/out
  touch pages/.nojekyll
  for d in pages/out/*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    case "$b" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) [ "${b:0:8}" -lt "$CUTOFF" ] && rm -rf "$d" || true ;; esac
  done
  rm -rf "pages/out/$BATCH_ID"
  cp -r "$KEEP/$BATCH_ID" "pages/out/$BATCH_ID"
  (
    cd pages
    git config user.name "reel-lab"
    git config user.email "actions@users.noreply.github.com"
    git checkout -q --orphan tmp 2>/dev/null || git checkout -q -b tmp
    git add -A
    git commit -q -m "batch $BATCH_ID"
    git push -q -f origin tmp:gh-pages
  ) && { PUSHED=1; break; }
  echo "Push abgelehnt (Versuch $TRY), neuer Versuch"
  sleep $(( (RANDOM % 8) + 3 ))
done
[ "$PUSHED" = 1 ] || { echo "Push endgueltig fehlgeschlagen"; exit 1; }
echo "Fertig: $i Varianten"
