#!/bin/bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <profile-name>"
  echo "Available profiles: vanilla, fabric-survival, create-modpack"
  exit 1
fi

PROFILE="$1"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
FUNCTION="${LAMBDA_FUNCTION:-mineops-prod-scaler}"

echo "[switch] Switching to profile: ${PROFILE}"

aws lambda invoke \
  --function-name "$FUNCTION" \
  --region "$REGION" \
  --payload "{\"action\": \"switch_profile\", \"profile\": \"${PROFILE}\"}" \
  /dev/stdout

echo ""
echo "[switch] Done. Server will restart with profile: ${PROFILE}"
