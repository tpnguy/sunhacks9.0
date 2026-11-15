#!/usr/bin/env bash
# Load clips/clips.json into the dubstudio-clips table, using YOUR local AWS creds.
#   ./seed.sh [extra args passed to cmd/seedclips]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_aws
[ -f "$OUTPUTS" ] || write_outputs

CLIPS_TABLE=$(out ClipsTable); export CLIPS_TABLE
TAKES_TABLE=$(out TakesTable); export TAKES_TABLE
export STORE=dynamo
export CLIPS_FILE=${CLIPS_FILE:-$ROOT_DIR/clips/clips.json}
[ -f "$CLIPS_FILE" ] || die "Missing $CLIPS_FILE"

log "Seeding $CLIPS_FILE -> $CLIPS_TABLE ($AWS_REGION)"
(cd "$ROOT_DIR/server" && go run ./cmd/seedclips "$@")

n=$(aws dynamodb scan --table-name "$CLIPS_TABLE" --select COUNT --query Count --output text)
log "$CLIPS_TABLE now has $n clip(s). Check: curl -s $(out BaseURL)/clips"
