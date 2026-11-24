#!/bin/bash
# Captures real photos and videos with build/Camera.app and checks each file's size, frame rate
# and audio. Needs a camera that does 24 and 30 fps, a microphone, and ffprobe (from ffmpeg).
# Pass part of a camera's name to pick one; otherwise Camera's own choice is used. A second name
# also checks a photo saves one file per camera and a video shows that camera in the corner. Every capture must finish in 20 s.
# Writes into ~/Pictures/Camera like the app does.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v ffprobe >/dev/null || { echo "test.sh needs ffprobe: brew install ffmpeg"; exit 1; }
CAMERA_ARGS=()
[ $# -gt 0 ] && CAMERA_ARGS=(--camera "$1")
SECOND=${2:-}
BIN=build/Camera.app/Contents/MacOS/Camera
./scripts/build.sh >/dev/null || exit 1  # never test a stale app
fail=0

capture() { perl -e 'alarm 20; exec @ARGV' "$BIN" ${CAMERA_ARGS[@]+"${CAMERA_ARGS[@]}"} "$@" 2>/dev/null | tail -1; }
check() {  # check <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
size() { ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=s=x:p=0 "$1" 2>/dev/null; }

for spec in "9:16 1080 1080x1920" "4:5 1080 1080x1350" "5:4 1080 1350x1080" "1:1 720 720x720" "16:9 1080 1920x1080"; do
  set -- $spec
  for rotate in 0 90; do
    f=$(capture --photo --aspect "$1" --res "$2" --rotate "$rotate")
    check "photo $1 ${2}p rotated $rotate" "$(size "$f")" "$3"
  done
done

# The first microphone from --list, so a mic muted in the app doesn't fail the sound checks.
MIC=$("$BIN" --list | sed -n '/^microphones:/{n;s/^  //p;}')
for fps in 24 30; do
  f=$(capture --record 3 --aspect 9:16 --fps "$fps" --mic "$MIC")
  check "video 9:16 size at $fps fps" "$(size "$f")" "1080x1920"
  frames=$(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$f" 2>/dev/null)
  seconds=$(ffprobe -v error -select_streams v -show_entries stream=duration -of csv=p=0 "$f" 2>/dev/null)
  measured=$(awk -v n="${frames:-0}" -v d="${seconds:-1}" 'BEGIN { printf "%d", n / d + 0.5 }')
  check "video frame rate at $fps fps" "$measured" "$fps"
  check "video has audio at $fps fps" "$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null)" "aac"
  check "video color tags at $fps fps" "$(ffprobe -v error -select_streams v -show_entries stream=color_space,color_transfer,color_primaries -of csv=p=0 "$f" 2>/dev/null)" "bt709,iec61966-2-1,bt709"
done

if [ -n "$SECOND" ]; then
  # The corner's light edge on a 1080x1920 frame: 4 px wide, its left side at x 709, rows 1297 to 1881.
  edge() { ffmpeg -v error -i "$1" -frames:v 1 -vf "crop=2:300:710:1440,format=gray" -f rawvideo - | od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d' | sort -n | head -1; }
  # A photo is one full file per camera, the main camera's first, with no corner drawn.
  photos=$(perl -e 'alarm 20; exec @ARGV' "$BIN" ${CAMERA_ARGS[@]+"${CAMERA_ARGS[@]}"} --photo --aspect 9:16 --res 1080 --second "$SECOND" 2>/dev/null)
  check "photo with $SECOND saves one file per camera" "$(printf '%s\n' "$photos" | grep -c '\.jpg$')" "2"
  while IFS= read -r f; do check "photo size of $(basename "$f")" "$(size "$f")" "1080x1920"; done <<< "$photos"
  f=$(capture --record 3 --aspect 9:16 --res 1080 --fps 30 --second "$SECOND" --mic "$MIC")
  check "video with $SECOND in the corner" "$(size "$f")" "1080x1920"
  check "corner edge is drawn in the video" "$([ "$(edge "$f")" -ge 180 ] 2>/dev/null && echo yes || echo no)" "yes"
fi

exit $fail
