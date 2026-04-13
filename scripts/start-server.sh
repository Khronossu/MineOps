#!/bin/bash
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
FUNCTION="${LAMBDA_FUNCTION:-mineops-dev-scaler}"

echo "Starting MineOps server..."

# Scale up and get IP
aws lambda invoke \
  --function-name "$FUNCTION" \
  --region "$REGION" \
  --payload '{"action": "scale_up"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda_response.json > /dev/null 2>&1

STATUS=$(python3 -c "import json; d=json.load(open('/tmp/lambda_response.json')); print(d.get('status',''))")
IP=$(python3 -c "import json; d=json.load(open('/tmp/lambda_response.json')); print(d.get('ip') or d.get('serverIp') or '')")

if [ "$STATUS" = "already_running" ] || [ "$STATUS" = "scaled_up" ]; then
  echo ""
  echo "Server IP : $IP"
  echo "Connect to: $IP:25565"
  echo ""
  echo "Waiting for server to boot..."
  for i in $(seq 1 18); do
    sleep 10
    LOG=$(aws logs tail /minecraft/server --since 3m --region "$REGION" 2>/dev/null | grep "Done" | tail -1)
    if echo "$LOG" | grep -q "Done"; then
      echo ""
      echo "Server is ready! Connect to: $IP:25565"
      exit 0
    fi
    printf "."
  done
  echo ""
  echo "Server taking longer than expected. Try connecting to: $IP:25565"
else
  echo "Error: $STATUS"
fi
