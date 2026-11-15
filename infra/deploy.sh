#!/usr/bin/env bash
# Create/update the `dubstudio` CloudFormation stack and its SSM config. Idempotent.
#   ./deploy.sh you@example.com        # email gets the $20/mo budget alert (optional)
# Env overrides: AWS_REGION (us-west-2), KEY_NAME (SSH key, discouraged), ENABLE_ALARMS=true,
#                ENABLE_PITR=true, BUDGET_USD=20
set -euo pipefail
source "$(dirname "$0")/lib.sh"

EMAIL=${1:-${BUDGET_EMAIL:-}}
require_aws

status=$(stack_status)
case "$status" in
  ROLLBACK_COMPLETE|ROLLBACK_FAILED|DELETE_FAILED)
    warn "Stack is in $status (failed first create) - deleting it before retrying"
    aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK"
    status=NONE ;;
  *_IN_PROGRESS) die "Stack is busy ($status). Wait and re-run." ;;
esac

params=()
if [ "$status" = NONE ] || [ "$status" = DELETE_COMPLETE ]; then
  # Pin the AMI at create time; later deploys keep it so the instance is never replaced by an AMI bump.
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
        --query Parameter.Value --output text)
  log "Creating stack with AL2023 arm64 AMI $AMI"
  params+=("ImageId=$AMI")
fi
[ -n "$EMAIL" ]                 && params+=("AlertEmail=$EMAIL")
[ -n "${KEY_NAME:-}" ]          && params+=("KeyName=$KEY_NAME")
[ -n "${ENABLE_ALARMS:-}" ]     && params+=("EnableAlarms=$ENABLE_ALARMS")
[ -n "${ENABLE_PITR:-}" ]       && params+=("EnablePITR=$ENABLE_PITR")
[ -n "${BUDGET_USD:-}" ]        && params+=("MonthlyBudgetUSD=$BUDGET_USD")

log "Deploying stack '$STACK' (takes ~3-5 min on first create)"
deploy_args=(--stack-name "$STACK" --template-file "$INFRA_DIR/template.yaml"
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags app=dubstudio)
if [ ${#params[@]} -gt 0 ]; then
  deploy_args+=(--parameter-overrides "${params[@]}")
fi
aws cloudformation deploy "${deploy_args[@]}"

write_outputs
log "Stack outputs -> $OUTPUTS"
cat "$OUTPUTS"

BUCKET=$(out BucketName)
BASE_URL=$(out BaseURL)

put_param() { # name value  (plain String)
  aws ssm put-parameter --name "/dubstudio/$1" --type String --value "$2" --overwrite >/dev/null
  echo "   /dubstudio/$1 = $2"
}

# Read KEY from ../server/.env without printing it.
env_from_dotenv() {
  local f="$ROOT_DIR/server/.env"
  [ -f "$f" ] || return 0
  grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$f" | tail -n1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//; s/^[\"']//; s/[\"'][[:space:]]*$//" || true
}

log "Writing config to SSM Parameter Store (/dubstudio/*)"
put_param MEDIA_BUCKET "$BUCKET"
put_param PUBLIC_BASE_URL "$BASE_URL"
put_param TAKES_TABLE "$(out TakesTable)"
put_param CLIPS_TABLE "$(out ClipsTable)"
put_param PLAYERS_TABLE "$(out PlayersTable)"
put_param STORE dynamo
put_param PORT 8080
put_param CLIPS_FILE /opt/dubstudio/clips.json
MODEL=$(env_from_dotenv GEMINI_MODEL)
[ -n "$MODEL" ] && put_param GEMINI_MODEL "$MODEL"
FALLBACK=$(env_from_dotenv GEMINI_FALLBACK_MODEL)
[ -n "$FALLBACK" ] && put_param GEMINI_FALLBACK_MODEL "$FALLBACK"
TIMEOUT=$(env_from_dotenv GEMINI_TIMEOUT_SECONDS)
[ -n "$TIMEOUT" ] && put_param GEMINI_TIMEOUT_SECONDS "$TIMEOUT"

GEMINI_API_KEY=$(env_from_dotenv GEMINI_API_KEY)
if [ -n "$GEMINI_API_KEY" ]; then
  # Pass the secret via a 0600 temp file (not argv, so it never shows in `ps` or shell history).
  tmp=$(umask 077; mktemp)
  trap 'rm -f "$tmp"' EXIT
  GEMINI_API_KEY="$GEMINI_API_KEY" python3 -c 'import json,os,sys; json.dump({"Name":"/dubstudio/GEMINI_API_KEY","Type":"SecureString","Overwrite":True,"Value":os.environ["GEMINI_API_KEY"]}, open(sys.argv[1],"w"))' "$tmp"
  aws ssm put-parameter --cli-input-json "file://$tmp" >/dev/null
  rm -f "$tmp"
  unset GEMINI_API_KEY
  echo "   /dubstudio/GEMINI_API_KEY = (SecureString, hidden)"
else
  warn "No GEMINI_API_KEY in server/.env - server will run in MOCK scoring mode until you add it and re-run deploy.sh"
fi

cat <<MSG

$(log "Done.")
   Base URL : $BASE_URL   (HTTPS cert appears ~1-2 min after the instance first boots)
   Next     : ./push.sh   (build + ship the Go server)   then   ./seed.sh   (load clips)
   Budget   : ${EMAIL:-"(no email given; pass one to enable the budget alert)"} - confirm the AWS Budgets email if asked
MSG
