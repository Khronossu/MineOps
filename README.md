# MineOps

Production-grade Minecraft server on AWS Fargate with EFS persistent storage, Terraform IaC, Lambda/RCON scale-to-zero, and S3-backed mod profile switching.

The server starts cold (zero cost at idle), scales up on first player connection via Lambda, and supports hot-swapping mod profiles without rebuilding the container image.

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
```

Scale-down: Lambda polls player count via RCON every N minutes → desiredCount=0 when empty

## Repository Structure

```
.
├── terraform/
│   ├── main.tf
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
│   │   └── handler.py
│   └── requirements.txt
├── docker/
│   ├── Dockerfile
│   └── start.sh
├── mods/
│   ├── vanilla/
│   ├── fabric-survival/
│   └── create-modpack/
└── scripts/
    ├── switch-profile.sh
    └── rcon.sh
```

## Quick Start

### Terraform deploy

```bash
cd terraform
terraform plan -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

### Switch mod profile

```bash
aws lambda invoke \
  --function-name minecraft-scaler \
  --payload '{"action": "switch_profile", "profile": "fabric-survival"}' \
  /dev/stdout
```

### Scale manually

```bash
# Up
aws ecs update-service --cluster minecraft-cluster --service minecraft-service --desired-count 1

# Down
aws ecs update-service --cluster minecraft-cluster --service minecraft-service --desired-count 0
```

### RCON

```bash
./scripts/rcon.sh "list"
./scripts/rcon.sh "say Hello"
./scripts/rcon.sh "stop"
```

## Branching Strategy

| Branch | Purpose |
|---|---|
| `main` | Stable, production-ready |
| `develop` | Integration branch — all features merge here first |
| `feat/*` | Feature branches cut from `develop` |

PRs: `feat/*` → `develop` → `main`
