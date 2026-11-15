#!/usr/bin/env bash
# Live, readable view of what the deployed server receives and what Gemini says.
#   ./logs.sh            follow new takes (Ctrl-C to stop)
#   ./logs.sh 30m        show the last 30 minutes, then follow
#   ./logs.sh --audio <take_id>   download the raw audio the iPad sent and inspect it
set -euo pipefail
REGION=${AWS_REGION:-us-west-2}
if [ "${1:-}" = "--audio" ]; then
  ID=${2:?take_id}; BUCKET=$(python3 -c 'import json;print(json.load(open("'"$(dirname "$0")"'/outputs.json"))["BucketName"])')
  OUT=${TMPDIR:-/tmp}/take-$ID.m4a
  aws s3 cp "s3://$BUCKET/dubs/$ID.take.m4a" "$OUT" --region "$REGION" >/dev/null
  echo "saved $OUT"; ffprobe -hide_banner "$OUT" 2>&1 | sed -n '/Input/,$p'
  ffmpeg -hide_banner -nostats -i "$OUT" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume' || true
  echo "play it:  afplay $OUT"; exit 0
fi
FOLLOW=--follow; [ -n "${NOFOLLOW:-}" ] && FOLLOW=
aws logs tail /dubstudio/server --region "$REGION" --since "${1:-5m}" $FOLLOW --format short \
  | grep --line-buffered -E 'take_received|take_scored_detail|gemini|"level":"(WARN|ERROR)"' \
  | python3 -u "$(dirname "$0")/logfmt.py"
