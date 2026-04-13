# MineOps — Implementation Plan

> Follow phases in order. Each phase is independently deployable and testable.
> Branch workflow: cut `feat/<name>` from `develop`, PR back to `develop`, merge `develop` → `main` on milestones.

---

## Phase 1 — Storage & Networking (Foundation)

Everything else depends on this existing first.

### 1.1 Terraform root module scaffold
- [ ] `terraform/main.tf` — provider block (AWS), backend config (S3 + DynamoDB state lock)
- [ ] `terraform/variables.tf` — shared vars: `region`, `environment`, `project_name`
- [ ] `terraform/outputs.tf` — placeholder, filled in later phases
- [ ] `terraform/environments/dev.tfvars` and `prod.tfvars`

### 1.2 Network module (`terraform/modules/network/`)
- [ ] VPC with DNS hostnames enabled
- [ ] 2x public subnets (Lambda, NAT), 2x private subnets (Fargate, EFS)
- [ ] Internet Gateway + NAT Gateway (private subnets need S3/SSM access)
- [ ] Security groups:
  - `sg-minecraft` — inbound TCP 25565 (players), inbound TCP 25575 (RCON, Lambda only)
  - `sg-efs` — inbound TCP 2049 from `sg-minecraft` only

### 1.3 Storage module (`terraform/modules/storage/`)
- [ ] S3 bucket for mod profiles (`minecraft-mods/`) — versioning on, public access blocked
- [ ] SSM parameters:
  - `/minecraft/active-profile` (String, default `"vanilla"`)
  - `/minecraft/rcon-password` (SecureString)
- [ ] Upload initial mod profile directories to S3:
  - `mods/vanilla/` → `s3://.../minecraft-mods/vanilla/`
  - `mods/fabric-survival/` → `s3://.../minecraft-mods/fabric-survival/`
  - `mods/create-modpack/` → `s3://.../minecraft-mods/create-modpack/`

### 1.4 EFS module (`terraform/modules/efs/`)
- [ ] EFS filesystem — encrypted at rest
- [ ] Mount targets in each private subnet
- [ ] EFS access point for `/minecraft` directory (uid/gid 1000)

**Milestone:** `terraform apply` creates VPC, S3, SSM, EFS with no errors. Verify mount manually.

---

## Phase 2 — Container

### 2.1 Dockerfile (`docker/Dockerfile`)
- [ ] Base image: `eclipse-temurin:21-jre` (or version matching server JAR)
- [ ] Install: `awscli`, `curl`, `mcrcon` (for RCON)
- [ ] Create user `minecraft` (uid 1000), working dir `/minecraft`
- [ ] `ENTRYPOINT ["bash", "/docker/start.sh"]`
- [ ] No `server.jar` baked in — it lives on EFS

### 2.2 Entrypoint script (`docker/start.sh`)
- [ ] Read active profile from SSM
- [ ] Wait loop for EFS mount readiness (check `/minecraft/mods/` exists, retry 10x / 3s)
- [ ] `aws s3 sync s3://${MOD_BUCKET}/minecraft-mods/${PROFILE}/ /minecraft/mods/ --delete`
- [ ] Print `profile.json` if present
- [ ] `exec java -Xms${JVM_MIN_MEM} -Xmx${JVM_MAX_MEM} -jar /minecraft/server.jar nogui`

### 2.3 ECR repository
- [ ] Terraform resource for ECR repo in `modules/ecs/`
- [ ] Build + push image: `docker build -t mineops ./docker && docker push <ecr-url>/mineops:latest`

### 2.4 First-time EFS setup (manual, once)
- [ ] Mount EFS locally or via a temporary EC2/task
- [ ] Place `server.jar` at `/minecraft/server.jar`
- [ ] Create `/minecraft/eula.txt` with `eula=true`
- [ ] Create `/minecraft/server.properties` (set `rcon.port=25575`, `enable-rcon=true`)

**Milestone:** Run container locally with EFS mounted, server boots and accepts connections.

---

## Phase 3 — ECS Fargate

### 3.1 ECS module (`terraform/modules/ecs/`)
- [ ] ECS cluster (`minecraft-cluster`)
- [ ] Task definition:
  - CPU: 1024, Memory: 4096 (adjustable via tfvars)
  - EFS volume mount → `/minecraft`
  - Environment vars: `MOD_BUCKET`, `JVM_MIN_MEM`, `JVM_MAX_MEM`
  - Secret: `RCON_PASSWORD` from SSM SecureString
- [ ] ECS service (`minecraft-service`):
  - `desired_count = 0` (starts off)
  - `launch_type = FARGATE`
  - Network config: private subnets, `sg-minecraft`
  - Deployment circuit breaker enabled

### 3.2 IAM roles
- [ ] **Task Execution Role** — ECR pull, CloudWatch Logs, SSM get `/minecraft/rcon-password`
- [ ] **Task Role** — SSM get `/minecraft/active-profile`, S3 get/list `minecraft-mods/*`

### 3.3 CloudWatch Logs
- [ ] Log group `/minecraft/server` with 7-day retention

**Milestone:** Manually set `desired_count = 1`, task runs, server is joinable, logs appear in CloudWatch.

---

## Phase 4 — Lambda (Scale-to-Zero + Profile Switch)

### 4.1 Lambda function (`lambda/scaler/handler.py`)
- [ ] **Action: `scale_up`** — set ECS desired count to 1, wait for RUNNING state
- [ ] **Action: `scale_down`** — RCON `list` → if 0 players, set desired count to 0
- [ ] **Action: `switch_profile`** — SSM PutParameter + `ecs:update-service --force-new-deployment`
- [ ] **Action: `status`** — return current ECS state + active profile

### 4.2 Lambda trigger for scale-down
- [ ] EventBridge rule: run `scale_down` check every 10 minutes
- [ ] Only fires if desired count is already 1 (skip when server is off)

### 4.3 Lambda module (`terraform/modules/lambda/`)
- [ ] Lambda function resource (Python 3.12 runtime)
- [ ] IAM role:
  - SSM get+put `/minecraft/active-profile`
  - ECS `UpdateService`, `DescribeServices` on `minecraft-cluster`
  - S3 `ListBucket` on mod bucket (profile validation)
- [ ] EventBridge rule + permission to invoke Lambda
- [ ] `requirements.txt` — `boto3` (included in runtime, but pin for local dev)

**Milestone:** Invoke Lambda manually for each action. Scale-down fires automatically after 10m of no players.

---

## Phase 5 — Scripts & Developer Tooling

### 5.1 `scripts/rcon.sh`
- [ ] Wrapper around `mcrcon` using RCON password from SSM
- [ ] Usage: `./scripts/rcon.sh "list"`

### 5.2 `scripts/switch-profile.sh`
- [ ] Invokes Lambda `switch_profile` action with profile name arg
- [ ] Usage: `./scripts/switch-profile.sh fabric-survival`

### 5.3 Mods directory structure (`mods/`)
- [ ] `mods/vanilla/` — empty placeholder + `profile.json`
- [ ] `mods/fabric-survival/` — fabric loader jar(s) + `profile.json`
- [ ] `mods/create-modpack/` — create mod jars + `profile.json`
- [ ] `profile.json` schema: `{ "mc_version": "1.21", "loader": "fabric", "mods": [...] }`

### 5.4 `.gitignore`
- [ ] Ignore: `.terraform/`, `*.tfstate`, `*.tfstate.backup`, `*.tfvars` (secrets), `__pycache__/`, `.env`

---

## Phase 6 — Hardening & Observability

### 6.1 CloudWatch alarms
- [ ] Alarm: ECS task in `STOPPED` state → SNS notification
- [ ] Alarm: Lambda error rate > 0 → SNS notification

### 6.2 Cost guardrails
- [ ] AWS Budget alert at $20/month
- [ ] Tag all resources: `Project=MineOps`, `Environment=dev|prod`

### 6.3 Backup
- [ ] EFS automatic backups enabled (AWS Backup)
- [ ] S3 versioning already on — add lifecycle rule to expire old versions after 30 days

### 6.4 Secrets rotation
- [ ] Document RCON password rotation procedure (SSM SecureString → redeploy task)

---

## Branch → Phase Mapping

| Feature branch | Phase |
|---|---|
| `feat/terraform-foundation` | Phase 1 |
| `feat/docker-container` | Phase 2 |
| `feat/ecs-fargate` | Phase 3 |
| `feat/lambda-scaler` | Phase 4 |
| `feat/scripts-tooling` | Phase 5 |
| `feat/observability` | Phase 6 |

---

## Environment Promotion

```
feat/* → develop (PR + review)
develop → main   (after each phase milestone is verified in dev env)
```

Tag `main` on each phase completion: `v1.0-storage`, `v2.0-container`, etc.
