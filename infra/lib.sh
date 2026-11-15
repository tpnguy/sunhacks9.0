# shellcheck shell=bash disable=SC2034
# Shared helpers for deploy.sh / push.sh / seed.sh / teardown.sh (sourced, not executed).
STACK=${STACK:-dubstudio}
export AWS_REGION=${AWS_REGION:-us-west-2}
export AWS_DEFAULT_REGION=$AWS_REGION
export AWS_PAGER=""
INFRA_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$INFRA_DIR/.." && pwd)
OUTPUTS="$INFRA_DIR/outputs.json"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

require_aws() {
  command -v aws >/dev/null || die "aws CLI not found"
  local who
  who=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) \
    || die "No AWS credentials. Run: aws login   (then re-run this script)"
  log "AWS identity: $who  region: $AWS_REGION"
}

stack_status() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE
}

write_outputs() {
  aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json \
    | python3 -c 'import json,sys; print(json.dumps({o["OutputKey"]: o["OutputValue"] for o in json.load(sys.stdin)}, indent=2))' \
    > "$OUTPUTS"
}

# out <Key>  -> value from outputs.json (refreshes it from CloudFormation if missing)
out() {
  [ -f "$OUTPUTS" ] || write_outputs
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUTPUTS" "$1"
}
