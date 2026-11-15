#!/usr/bin/env bash
# DESTROYS everything: EC2 + Elastic IP, all DynamoDB data, all S3 media, SSM /dubstudio/* params.
#   ./teardown.sh --yes
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cat >&2 <<'WARN'

  ################################################################
  #  WARNING: this permanently deletes the dubstudio stack:      #
  #   - EC2 instance + Elastic IP (the sslip.io URL dies)        #
  #   - ALL DynamoDB tables (takes, leaderboard, clips, players) #
  #   - ALL objects in the media bucket (dubs, clips, deploys)   #
  #   - SSM parameters /dubstudio/* (incl. the Gemini key)       #
  ################################################################

WARN
[ "${1:-}" = "--yes" ] || die "Refusing to run without --yes"

require_aws
status=$(stack_status)
[ "$status" = NONE ] && { warn "Stack $STACK does not exist"; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="dubstudio-media-$ACCOUNT"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  log "Emptying s3://$BUCKET"
  aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
fi

if [ "$status" != NONE ]; then
  log "Deleting stack $STACK (a few minutes)"
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
fi

names=$(aws ssm get-parameters-by-path --path /dubstudio/ --query 'Parameters[].Name' --output text 2>/dev/null || true)
if [ -n "$names" ]; then
  log "Deleting SSM parameters"
  # delete-parameters takes at most 10 names per call
  echo $names | xargs -n 10 aws ssm delete-parameters --names >/dev/null
fi

rm -f "$OUTPUTS"
log "Teardown complete. Double-check the Billing console tomorrow."
