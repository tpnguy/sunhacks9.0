#!/usr/bin/env bash
# Build the Go server for linux/arm64, ship it to EC2 via S3 + SSM Run Command, restart, health-check.
#   ./push.sh              # build + deploy
#   ./push.sh --no-build   # deploy the existing server/bin/dubstudio-server-linux-arm64
set -euo pipefail
source "$(dirname "$0")/lib.sh"

BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0
require_aws
[ -f "$OUTPUTS" ] || write_outputs

BUCKET=$(out BucketName)
IID=$(out InstanceId)
HOST=$(out Host)
BIN="$ROOT_DIR/server/bin/dubstudio-server-linux-arm64"

if [ "$BUILD" = 1 ]; then
  log "Building linux/arm64 binary (make build-linux)"
  (cd "$ROOT_DIR/server" && make build-linux)
fi
[ -f "$BIN" ] || die "Binary not found: $BIN"

log "Bundling binary + prompts + clips.json + unit files"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/bundle"
cp "$BIN" "$STAGE/bundle/dubstudio-server"
cp "$INFRA_DIR/dubstudio.service" "$INFRA_DIR/Caddyfile.tmpl" \
   "$INFRA_DIR/remote/install.sh" "$INFRA_DIR/remote/fetch-env.sh" "$STAGE/bundle/"
[ -f "$ROOT_DIR/clips/clips.json" ] && cp "$ROOT_DIR/clips/clips.json" "$STAGE/bundle/"
if [ -d "$ROOT_DIR/prompts" ] && [ -n "$(ls -A "$ROOT_DIR/prompts")" ]; then
  cp -R "$ROOT_DIR/prompts" "$STAGE/bundle/prompts"
fi
COPYFILE_DISABLE=1 tar -czf "$STAGE/bundle.tar.gz" -C "$STAGE/bundle" .
KEY="deploy/bundle.tar.gz"
aws s3 cp "$STAGE/bundle.tar.gz" "s3://$BUCKET/$KEY" --only-show-errors
log "Uploaded s3://$BUCKET/$KEY ($(du -h "$STAGE/bundle.tar.gz" | cut -f1))"

log "Waiting for SSM agent on $IID to be Online"
for i in $(seq 1 60); do
  ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$IID" \
         --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
  [ "$ping" = Online ] && break
  [ "$i" = 60 ] && die "SSM agent never came Online (instance still booting? role attached?)"
  sleep 5
done

PARAMS=$(python3 -c 'import json,sys; b,k,h,r=sys.argv[1:]; print(json.dumps({"commands":[
  "set -euo pipefail",
  "rm -rf /tmp/dubstudio-bundle && mkdir -p /tmp/dubstudio-bundle",
  f"aws s3 cp s3://{b}/{k} /tmp/dubstudio-bundle.tar.gz --region {r} --only-show-errors",
  "tar -xzf /tmp/dubstudio-bundle.tar.gz -C /tmp/dubstudio-bundle",
  f"bash /tmp/dubstudio-bundle/install.sh {h}"],
  "executionTimeout":["900"]}))' "$BUCKET" "$KEY" "$HOST" "$AWS_REGION")

log "Running install on $IID via SSM Run Command"
CMD_ID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --comment "dubstudio push" --parameters "$PARAMS" --query Command.CommandId --output text)

status=Pending
for i in $(seq 1 180); do
  status=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
           --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$IID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -n 40
[ "$status" = Success ] || die "Remote install finished with status: $status (see output above; logs: aws logs tail /dubstudio/server --follow)"

log "Polling https://$HOST/healthz"
for i in $(seq 1 36); do
  if body=$(curl -fsS --max-time 5 "https://$HOST/healthz" 2>/dev/null); then
    log "LIVE: https://$HOST  ->  $body"
    exit 0
  fi
  sleep 5
done
warn "Server is healthy on the box but HTTPS isn't answering yet (Let's Encrypt cert still issuing?)."
warn "Debug: aws ssm start-session --target $IID   then   sudo journalctl -u caddy -n 50"
exit 1
