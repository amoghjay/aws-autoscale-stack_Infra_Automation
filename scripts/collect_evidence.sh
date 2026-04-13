#!/usr/bin/env bash
# Collect AWS scaling evidence over time.
# Run from the repo root:
#   bash scripts/collect_evidence.sh
#   bash scripts/collect_evidence.sh --duration 600 --interval 30

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DURATION=0
INTERVAL=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)
      DURATION="${2:?missing value for --duration}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:?missing value for --interval}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: bash scripts/collect_evidence.sh [--duration SECONDS] [--interval SECONDS]" >&2
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_OUTPUTS_JSON="$ROOT_DIR/ansible/inventory/tf_outputs.json"
OUT_DIR="$ROOT_DIR/evidence"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="$OUT_DIR/scaling_evidence_${STAMP}.txt"

mkdir -p "$OUT_DIR"

if [[ ! -f "$TF_OUTPUTS_JSON" ]]; then
  echo "Missing $TF_OUTPUTS_JSON. Generate it with: cd terraform && terraform output -json > ../ansible/inventory/tf_outputs.json" >&2
  exit 1
fi

read_json() {
  python3 - "$TF_OUTPUTS_JSON" "$1" <<'PY'
import json
import sys

path = sys.argv[1]
key = sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
print(data[key]["value"])
PY
}

ASG_NAME="$(read_json asg_name)"
TG_ARN="$(read_json alb_target_group_arn)"
ALB_DNS="$(read_json alb_dns_name)"

ALB_ARN="$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn | [0]" \
  --output text)"

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  echo "Could not resolve ALB ARN from DNS name: $ALB_DNS" >&2
  exit 1
fi

ALB_DIMENSION="${ALB_ARN#*:loadbalancer/}"
TG_DIMENSION="${TG_ARN#*:targetgroup/}"

echo "Collecting scaling evidence -> $OUT"
echo "ASG: $ASG_NAME"
echo "ALB: $ALB_DNS"
echo "Target group: $TG_ARN"

sample() {
  {
    echo ""
    echo "========================================"
    echo "Collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "========================================"

    echo ""
    echo "=== ASG Scaling Activities ==="
    aws autoscaling describe-scaling-activities \
      --auto-scaling-group-name "$ASG_NAME" \
      --region "$REGION" \
      --max-items 20 \
      --query 'Activities[*].{Time:StartTime,Status:StatusCode,Cause:Cause}' \
      --output table

    echo ""
    echo "=== ASG Instance Count ==="
    aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$REGION" \
      --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:length(Instances)}' \
      --output table

    echo ""
    echo "=== ALB Target Health ==="
    aws elbv2 describe-target-health \
      --target-group-arn "$TG_ARN" \
      --region "$REGION" \
      --query 'TargetHealthDescriptions[*].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
      --output table

    echo ""
    echo "=== CloudWatch CPUUtilization (ASG) ==="
    aws cloudwatch get-metric-statistics \
      --region "$REGION" \
      --namespace AWS/EC2 \
      --metric-name CPUUtilization \
      --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
      --start-time "$(date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)" \
      --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --period 60 \
      --statistics Average Maximum \
      --output table

    echo ""
    echo "=== CloudWatch RequestCount (ALB) ==="
    aws cloudwatch get-metric-statistics \
      --region "$REGION" \
      --namespace AWS/ApplicationELB \
      --metric-name RequestCount \
      --dimensions Name=LoadBalancer,Value="$ALB_DIMENSION" \
      --start-time "$(date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)" \
      --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --period 60 \
      --statistics Sum \
      --output table

    echo ""
    echo "=== CloudWatch HealthyHostCount (ALB target group) ==="
    aws cloudwatch get-metric-statistics \
      --region "$REGION" \
      --namespace AWS/ApplicationELB \
      --metric-name HealthyHostCount \
      --dimensions Name=TargetGroup,Value="$TG_DIMENSION" Name=LoadBalancer,Value="$ALB_DIMENSION" \
      --start-time "$(date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)" \
      --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --period 60 \
      --statistics Average Minimum \
      --output table
  } | tee -a "$OUT"
}

if [[ "$DURATION" -le 0 ]]; then
  sample
else
  START_TS="$(date +%s)"
  while true; do
    sample
    NOW_TS="$(date +%s)"
    ELAPSED="$((NOW_TS - START_TS))"
    if [[ "$ELAPSED" -ge "$DURATION" ]]; then
      break
    fi
    sleep "$INTERVAL"
  done
fi

echo ""
echo "Done. Evidence saved to $OUT"
