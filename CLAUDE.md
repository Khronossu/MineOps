# CLAUDE.md — Minecraft Server (Fargate + EFS + Terraform)

## Project Overview

Production-grade Minecraft server on AWS Fargate with EFS persistent storage,
Terraform IaC, Lambda/RCON scale-to-zero, and S3-backed mod profile switching.

The server starts cold (zero cost at idle), scales up on first player connection via
Lambda, and supports hot-swapping mod profiles without rebuilding the container image.

---

## Repository Structure

```
.
├── terraform/
│   ├── main.tf                  # Root module, provider config
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   │   ├── network/             # VPC, subnets, SGs
│   │   ├── ecs/                 # Fargate cluster, service, task definition
│   │   ├── efs/                 # EFS filesystem + mount targets
│   │   ├── lambda/              # Scale-to-zero + profile switch functions
│   │   └── storage/             # S3 bucket, SSM parameters
│   └── environments/
│       ├── dev.tfvars
│       └── prod.tfvars
├── lambda/
│   ├── scaler/
│   │   └── handler.py           # Scale-up/down + profile switch logic
│   └── requirements.txt
├── docker/
│   ├── Dockerfile
│   └── start.sh                 # Entrypoint: SSM read → S3 sync → java
├── mods/
│   ├── vanilla/                 # Empty dir (placeholder)
│   ├── fabric-survival/         # .jar files or manifest
│   └── create-modpack/
└── scripts/
    ├── switch-profile.sh        # Local helper to trigger profile switch
    └── rcon.sh                  # Wrapper for RCON commands
```

---

## Architecture

```
Player connection attempt
        │
        ▼
  Route 53 / IP
        │
        ▼
  Lambda (scale-up)
   - Check ECS service desiredCount
   - If 0 → set to 1, wait for healthy
   - If already running → no-op
        │
        ▼
  Fargate Task (minecraft container)
   - Reads /minecraft/active-profile from SSM
   - Syncs s3://bucket/minecraft-mods/{profile}/ → EFS /minecraft/mods/ --delete
   - Starts server JAR
        │
        ▼
  EFS Mount
   /minecraft/
     ├── world/          ← persists forever, never touched by profile switch
     ├── mods/           ← wiped+replaced on each profile switch
     ├── server.jar      ← lives on EFS, not in image
     └── server.properties

Scale-down: Lambda polls player count via RCON every N minutes → desiredCount=0 when empty
```

**SSM Parameters**

| Parameter | Type | Purpose |
|---|---|---|
| `/minecraft/active-profile` | String | Which mod profile to load on next start |
| `/minecraft/rcon-password` | SecureString | RCON auth, read by container at runtime |

---

## Key Design Decisions

**Why server JAR on EFS, not in image?**
Changing MC version does not require a new image build or ECR push. Update EFS, restart task.

**Why `aws s3 sync --delete`?**
Without `--delete`, switching from a 30-mod pack to vanilla leaves all 30 jars in place and
the server crashes. `--delete` makes EFS /mods/ exactly mirror the S3 profile directory.

**Why SSM for active profile, not an env var?**
Env vars require a new task definition revision + deployment to change. SSM is read at
container startup — switch profile, force new deployment, done.

**Why forceNewDeployment for profile switch, not task stop?**
Fargate replaces the task rather than restarting it. Stopping the task directly risks the
service not launching a replacement if desired count was already 0. forceNewDeployment is
idempotent and works regardless of current state.

**World isolation**
Only `/minecraft/mods/` is swapped per profile. `/minecraft/world/` is never touched.
If you want per-profile worlds, use `/minecraft/world-{profile}/` on EFS and symlink
`/minecraft/world` → `/minecraft/world-{active-profile}/` in `start.sh`.

---

## Common Operations

### Switch mod profile

```bash
# Via Lambda (preferred — handles ECS restart)
aws lambda invoke \
  --function-name minecraft-scaler \
  --payload '{"action": "switch_profile", "profile": "fabric-survival"}' \
  /dev/stdout

# Or manually (you still need to force a redeploy after)
aws ssm put-parameter \
  --name /minecraft/active-profile \
  --value "fabric-survival" \
  --overwrite
aws ecs update-service \
  --cluster minecraft-cluster \
  --service minecraft-service \
  --force-new-deployment
```

### Add a new mod profile

1. Create `mods/<profile-name>/` locally with the `.jar` files
2. Upload to S3: `aws s3 sync mods/<profile-name>/ s3://bucket/minecraft-mods/<profile-name>/`
3. (Optional) Add a `profile.json` in the S3 directory documenting MC version + loader

### Scale server up/down manually

```bash
# Up
aws ecs update-service --cluster minecraft-cluster --service minecraft-service --desired-count 1

# Down
aws ecs update-service --cluster minecraft-cluster --service minecraft-service --desired-count 0
```

### Run RCON command

```bash
./scripts/rcon.sh "list"          # show online players
./scripts/rcon.sh "say Hello"     # broadcast message
./scripts/rcon.sh "stop"          # graceful shutdown
```

### Terraform apply

```bash
cd terraform
terraform plan -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

---

## Container Entrypoint (`docker/start.sh`)

```bash
#!/bin/bash
set -euo pipefail

PROFILE=$(aws ssm get-parameter \
  --name /minecraft/active-profile \
  --query Parameter.Value \
  --output text)

echo "[start] Active profile: ${PROFILE}"

# Wipe mods dir and sync from S3
aws s3 sync "s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/" /minecraft/mods/ --delete

# Validate profile.json if present
if [ -f /minecraft/mods/profile.json ]; then
  echo "[start] Profile metadata:"
  cat /minecraft/mods/profile.json
fi

echo "[start] Starting server..."
exec java \
  -Xms${JVM_MIN_MEM:-1G} \
  -Xmx${JVM_MAX_MEM:-3G} \
  -jar /minecraft/server.jar \
  nogui
```

Environment variables expected by the container:

| Variable | Source | Example |
|---|---|---|
| `MOD_BUCKET` | Task def env | `my-minecraft-bucket` |
| `JVM_MIN_MEM` | Task def env | `1G` |
| `JVM_MAX_MEM` | Task def env | `3G` |
| `RCON_PASSWORD` | SSM SecureString via secrets | injected at runtime |

---

## IAM Boundaries

**Task Execution Role** (ECS agent, image pull, secrets injection):
- `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`
- `ssm:GetParameter` on `/minecraft/rcon-password` only

**Task Role** (container process itself):
- `ssm:GetParameter` on `/minecraft/active-profile`
- `s3:GetObject`, `s3:ListBucket` on `minecraft-mods/*`

**Lambda Role**:
- `ssm:GetParameter`, `ssm:PutParameter` on `/minecraft/active-profile`
- `ecs:UpdateService`, `ecs:DescribeServices` on the minecraft cluster
- `s3:ListBucket` on mod bucket (for profile validation)

Principle: task role cannot write SSM. Only Lambda can change active profile.
This prevents a compromised container from switching its own mods.

---

## Gotchas

- **EFS mount takes ~10s after task start.** `start.sh` uses `set -e` — if the mount isn't
  ready when S3 sync runs, the task exits. Add a readiness check loop if you see
  "No such file or directory" on `/minecraft/mods/`.

- **Fargate task stops if server process exits.** A crash loop will hit ECS's circuit
  breaker after 3 failures and stop deploying. Check CloudWatch Logs first before
  assuming an infra issue.

- **`server.jar` is loader-specific.** Fabric and Forge JARs are not interchangeable.
  Either maintain separate JARs on EFS per loader type and symlink based on
  `profile.json`, or keep a single vanilla JAR and layer Fabric on top.

- **Scale-to-zero means cold start latency.** Fargate cold start is ~30–60s before the
  server is actually joinable. Set player expectation or use a status bot.

- **EULA.** `eula.txt` must exist on EFS with `eula=true`. Server won't start without it.
  Create it once manually after first EFS mount.

---

## Files Never to Modify via Automation

- `/minecraft/world/` — only modified by the running server process
- `/minecraft/whitelist.json` — manage via RCON (`whitelist add <player>`)
- `/minecraft/ops.json` — manage via RCON (`op <player>`)
