#!/bin/bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <rcon-command>"
  echo "Examples:"
  echo "  $0 list"
  echo "  $0 'say Hello'"
  echo "  $0 stop"
  exit 1
fi

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
CLUSTER="${ECS_CLUSTER:-mineops-prod-cluster}"
SERVICE="${ECS_SERVICE:-mineops-prod-service}"

RCON_PASSWORD=$(aws ssm get-parameter \
  --name /minecraft/rcon-password \
  --with-decryption \
  --region "$REGION" \
  --query Parameter.Value \
  --output text)

# Get task public IP
TASK_ARN=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name "$SERVICE" \
  --desired-status RUNNING \
  --region "$REGION" \
  --query 'taskArns[0]' \
  --output text)

if [ "$TASK_ARN" = "None" ] || [ -z "$TASK_ARN" ]; then
  echo "No running tasks found. Is the server up?"
  exit 1
fi

ENI_ID=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$TASK_ARN" \
  --region "$REGION" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

SERVER_IP=$(aws ec2 describe-network-interfaces \
  --network-interface-ids "$ENI_ID" \
  --region "$REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text)

echo "[rcon] Connecting to ${SERVER_IP}:25575..."
mcrcon -H "$SERVER_IP" -P 25575 -p "$RCON_PASSWORD" "$1"
