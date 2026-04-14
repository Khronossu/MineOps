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
  if findmnt /minecraft > /dev/null 2>&1; then
    echo "[start] EFS ready."
    mkdir -p /minecraft/mods
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "[start] ERROR: EFS mount not ready after 30s. Exiting."
    exit 1
  fi
  echo "[start] EFS not ready, retrying in 3s... (${i}/10)"
  sleep 3
done

# Fetch profile.json from S3 to determine loader and Java version
echo "[start] Fetching profile metadata..."
aws s3 cp "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/profile.json" /tmp/profile.json 2>/dev/null || echo '{}' > /tmp/profile.json

LOADER=$(python3 -c "import json; d=json.load(open('/tmp/profile.json')); print(d.get('loader','vanilla'))" 2>/dev/null || echo "vanilla")
MC_VERSION=$(python3 -c "import json; d=json.load(open('/tmp/profile.json')); print(d.get('mc_version','1.21'))" 2>/dev/null || echo "1.21")
MINOR=$(echo "$MC_VERSION" | cut -d. -f2)

echo "[start] Loader: ${LOADER}, MC version: ${MC_VERSION}"

# Select Java version
if [ "$MINOR" -le 16 ]; then
  JAVA_BIN="/usr/lib/jvm/java-8-openjdk-amd64/bin/java"
  echo "[start] Using Java 8"
else
  JAVA_BIN="java"
  echo "[start] Using Java 21"
fi

# Always sync the correct server.jar from S3 for this profile
echo "[start] Syncing server.jar for profile '${PROFILE}'..."
aws s3 cp "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/server.jar" /minecraft/server.jar

# For Forge profiles, sync libraries too
if [ "$LOADER" = "forge" ]; then
  echo "[start] Syncing Forge libraries..."
  aws s3 sync "s3://${MOD_BUCKET}/setup/libraries/" /minecraft/libraries/ --delete
  aws s3 cp "s3://${MOD_BUCKET}/setup/minecraft_server.${MC_VERSION}.jar" "/minecraft/minecraft_server.${MC_VERSION}.jar" 2>/dev/null || true
fi

# Ensure eula.txt exists
echo "eula=true" > /minecraft/eula.txt

# Sync mods from S3
echo "[start] Syncing mods from S3..."
aws s3 sync "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/" /minecraft/mods/ \
  --delete \
  --exclude "server.jar" \
  --exclude "profile.json"

# Sync extra folders (config, scripts, resources, structures)
for DIR in config scripts resources structures; do
  if aws s3 ls "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/${DIR}/" > /dev/null 2>&1; then
    echo "[start] Syncing ${DIR}..."
    aws s3 sync "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/${DIR}/" "/minecraft/${DIR}/" --delete
  fi
done

# Copy server.properties from S3 (ensures RCON and other settings are always correct)
aws s3 cp "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/server.properties" /minecraft/server.properties 2>/dev/null || true

echo "[start] Starting Minecraft server..."
exec "$JAVA_BIN" \
  -Xms${JVM_MIN_MEM:-6G} \
  -Xmx${JVM_MAX_MEM:-6G} \
  -XX:+UseG1GC \
  -XX:+UnlockExperimentalVMOptions \
  -XX:MaxGCPauseMillis=50 \
  -XX:G1NewSizePercent=20 \
  -XX:G1ReservePercent=20 \
  -XX:G1HeapRegionSize=32M \
  -jar /minecraft/server.jar \
  nogui
