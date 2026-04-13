#!/bin/bash
set -euo pipefail

PROFILE=$(aws ssm get-parameter \
  --name /minecraft/active-profile \
  --query Parameter.Value \
  --output text)

echo "[start] Active profile: ${PROFILE}"

# Wait for EFS mount to be ready
echo "[start] Waiting for EFS mount..."
for i in $(seq 1 10); do
  if [ -d /minecraft/mods ]; then
    echo "[start] EFS ready."
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "[start] ERROR: EFS mount not ready after 30s. Exiting."
    exit 1
  fi
  echo "[start] EFS not ready, retrying in 3s... (${i}/10)"
  sleep 3
done

# Sync mod profile from S3
echo "[start] Syncing mod profile '${PROFILE}' from S3..."
aws s3 sync "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/" /minecraft/mods/ --delete
echo "[start] Mod sync complete."

# Print profile metadata if present
if [ -f /minecraft/mods/profile.json ]; then
  echo "[start] Profile metadata:"
  cat /minecraft/mods/profile.json
fi

echo "[start] Starting Minecraft server..."
exec java \
  -Xms${JVM_MIN_MEM:-1G} \
  -Xmx${JVM_MAX_MEM:-3G} \
  -jar /minecraft/server.jar \
  nogui
