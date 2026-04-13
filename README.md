# MineOps

**A production-grade Minecraft server that costs almost nothing when no one's playing.**

Idle cost: ~$2/month. Active cost: ~$0.12/hour. No always-on EC2, no dedicated host, no wasted compute. Click a button on the web panel, wait three minutes, connect via your own domain.

Built with AWS Fargate, EFS, Lambda, Terraform, Docker, Cloudflare DNS — a full serverless stack around a vanilla/modded Minecraft server.

![Control Panel](https://img.shields.io/badge/control--panel-live-brightgreen) ![Terraform](https://img.shields.io/badge/terraform-IaC-623CE4) ![AWS](https://img.shields.io/badge/AWS-Fargate-FF9900) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## How it works

```
                     Player
                        │
                        ▼
         ┌──────────────────────────────┐
         │  play.yourdomain.com:25565   │  ←─── Cloudflare DNS (auto-updated)
         └──────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │  Fargate Task (Minecraft)    │  ←─── desiredCount: 0 → 1 on click
         │  • Reads active profile from │
         │    SSM Parameter Store       │
         │  • Syncs mods from S3 to EFS │
         │  • Starts the JAR            │
         └──────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │  EFS (persistent storage)    │
         │  /minecraft/world/           │  ←─── never wiped
         │  /minecraft/mods/            │  ←─── replaced per profile
         │  /minecraft/server.jar       │
         └──────────────────────────────┘

   Every 10 min: Lambda → RCON → "list"  →  if 0 players, scale to 0
   On start-up:  Lambda → ECS scale to 1 → Cloudflare DNS update
```

**Three key tricks**:

1. **Scale-to-zero Fargate.** The task only runs while someone's playing. Idle = $0 compute.
2. **RCON player detection.** Lambda pings the server every 10 minutes and only shuts it down when empty.
3. **Mods live on S3 + EFS, not in the image.** Switch from vanilla to RLCraft without rebuilding anything.

---

## Cost

At ~4 hours/day of active play:

| Resource | Cost/mo |
|---|---|
| Fargate (2 vCPU, 8 GB, ~120 hr) | ~$14 |
| Public IPv4 (per active hour) | ~$0.60 |
| Data transfer out (~5 GB/session) | ~$5–15 |
| EFS storage (~5 GB) | ~$1.50 |
| S3 mod bucket (~10 GB) | ~$0.23 |
| CloudWatch logs | ~$1 |
| Lambda, API Gateway, SSM, VPC, ECR | $0 (free tier) |
| **Total** | **~$23–32** |

**Idle when nobody plays: ~$2/month.**

---

## Features

- 🔘 **One-click web panel** — `play.yourdomain.com`, shows live player count, click to boot
- 🎮 **Modpack hot-swap** — switch between vanilla, RLCraft, Create, anything — one command
- 🧠 **RCON-based auto-shutoff** — no players for 10 min → server scales down
- 🌐 **Dynamic DNS** — Cloudflare A record updates on every boot, domain always works
- 💾 **Persistent world on EFS** — survives restarts and profile switches
- 🔐 **Least-privilege IAM** — task role can't modify active profile; only Lambda can
- 🏗 **100% Terraform** — every piece of infra is code; `terraform destroy` leaves nothing behind

---

## Prerequisites

- **AWS account** with admin access
- **Terraform** ≥ 1.5
- **Docker** (for building the container)
- **AWS CLI** configured with credentials
- **Domain** on Cloudflare (any registrar works, as long as nameservers point to Cloudflare)
- **Cloudflare API token** with `Zone.DNS:Edit` permission

---

## Deployment

### 1. Configure your variables

Copy `terraform/environments/dev.tfvars.example` (or edit `dev.tfvars`):

```hcl
environment        = "dev"
mod_bucket_name    = "yourproject-mods-dev"
jvm_min_mem        = "1G"
jvm_max_mem        = "7G"
cloudflare_zone_id = "<your-zone-id>"
domain_name        = "play.yourdomain.com"
```

### 2. Store secrets in SSM (one-time)

```bash
aws ssm put-parameter --name /minecraft/rcon-password --value "<strong-password>" --type SecureString
aws ssm put-parameter --name /minecraft/cloudflare-api-token --value "<token>" --type SecureString
aws ssm put-parameter --name /minecraft/active-profile --value "vanilla" --type String
```

### 3. Apply Terraform

```bash
cd terraform
terraform init
terraform apply -var-file=environments/dev.tfvars
```

This creates: VPC, Fargate cluster, EFS filesystem, S3 bucket, Lambda scaler, API Gateway, CloudWatch EventBridge schedule, ECR repo, IAM roles.

### 4. Build and push the container

```bash
cd docker
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <ecr-url>
docker build -t mineops .
docker tag mineops:latest <ecr-url>:latest
docker push <ecr-url>:latest
```

### 5. Upload your first mod profile

See [Switching mod profiles](#switching-mod-profiles) below.

### 6. Deploy the web control panel

Connect the repo to **Cloudflare Workers & Pages** → Git. Production branch: `main`. Deploy command: `npx wrangler deploy`. Add a custom domain like `play.yourdomain.com`.

---

## Switching mod profiles

Profiles live on S3 at `s3://<bucket>/minecraft-mods/<profile-name>/`. Each contains:

- `server.jar` — the server JAR (vanilla, Forge, Fabric, whatever)
- `server.properties` — server config (must have `enable-rcon=true`)
- `profile.json` — metadata: `{ "mc_version": "1.12.2", "loader": "forge", "loader_version": "14.23.5.2860" }`
- Mod `.jar` files at the root
- `config/`, `scripts/`, `resources/`, `structures/` folders (optional, synced if present)

### Add a new profile

```bash
# Local layout
mods/myprofile/
├── server.jar
├── server.properties
├── profile.json
├── somemod-1.0.jar
├── othermod-2.0.jar
└── config/
    └── somemod.cfg

# Upload
aws s3 sync mods/myprofile/ s3://<your-bucket>/minecraft-mods/myprofile/
```

### Switch the active profile

```bash
aws lambda invoke \
  --function-name mineops-dev-scaler \
  --payload '{"action":"switch_profile","profile":"myprofile"}' \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

The next container start will sync the new profile from S3 to EFS. `/minecraft/world/` is **never touched** — your world survives across profile switches.

**Note on Forge**: Forge 1.12.2 needs Java 8, 1.18+ needs Java 17+, 1.21+ needs Java 21. The container auto-selects Java based on `profile.json.mc_version`.

---

## Modifying `server.properties`

Edit `mods/<profile>/server.properties`, then:

```bash
aws s3 cp mods/<profile>/server.properties s3://<bucket>/minecraft-mods/<profile>/server.properties
aws ecs update-service --cluster mineops-dev-cluster --service mineops-dev-service --force-new-deployment
```

The container copies `server.properties` from S3 on every boot, so this always reflects what's on S3.

---

## Starting the server

### Via web panel (easiest)

Open `play.yourdomain.com` → click **Boot Server** → wait 3 min → connect via `yourdomain.com:25565`.

### Via shell script

```bash
./scripts/start-server.sh
```

Returns the server IP and polls until "Done" appears in logs.

### Via Lambda directly

```bash
aws lambda invoke --function-name mineops-dev-scaler \
  --payload '{"action":"scale_up"}' \
  --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json
```

---

## Admin commands (RCON)

```bash
RCON_PASS=$(aws ssm get-parameter --name /minecraft/rcon-password --with-decryption --query Parameter.Value --output text)
IP=$(getent hosts play.yourdomain.com | awk '{print $1}')

# Using bundled mcrcon
PYTHONPATH=lambda/scaler python3 -c "
import mcrcon, os
r = mcrcon.MCRcon('$IP', '$RCON_PASS', port=25575)
r.connect()
print(r.command('op PlayerName'))
r.disconnect()
"
```

Common commands:
- `op <player>` — grant operator
- `whitelist add <player>` — add to whitelist
- `list` — who's online
- `say <msg>` — broadcast
- `stop` — graceful shutdown

---

## Repository structure

```
.
├── terraform/
│   ├── main.tf                          # Root module, provider, backend
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   │   ├── network/                     # VPC, subnets, IGW, S3 endpoint, SGs
│   │   ├── ecs/                         # Fargate cluster, service, task def, ECR
│   │   ├── efs/                         # EFS filesystem + mount targets
│   │   ├── lambda/                      # Scaler Lambda + API Gateway + EventBridge
│   │   └── storage/                     # S3 bucket + lifecycle rules
│   └── environments/
│       └── dev.tfvars
├── lambda/
│   └── scaler/
│       ├── handler.py                   # scale_up, scale_down, switch_profile, web_status
│       └── mcrcon.py                    # bundled RCON client
├── docker/
│   ├── Dockerfile                       # eclipse-temurin:21 + Java 8 + awscli + mcrcon
│   └── start.sh                         # entrypoint: SSM → S3 sync → Java
├── web/
│   └── index.html                       # Cloudflare Pages control panel
├── mods/                                # Local mod profiles (source for S3 upload)
│   ├── vanilla/
│   └── rlcraft/
├── scripts/
│   └── start-server.sh                  # One-command boot + IP retrieval
├── wrangler.toml                        # Cloudflare Workers assets config
└── CLAUDE.md                            # Project notes
```

---

## Troubleshooting

**`io.netty.*Connection refused` when connecting**
The server isn't running or the DNS is stale. Open the web panel, check state. If offline, click Boot Server.

**Server shuts down while I'm playing**
RCON can't reach the server. Check:
- `server.properties` has `enable-rcon=true`
- Security group allows 25575 from `0.0.0.0/0` (password-protected, safe)
- SSM parameter `/minecraft/rcon-password` matches `server.properties` `rcon.password`

**Missing textures (magenta/black checker)**
Client issue, not server. Check:
- Client has all mods the server has (CurseForge modpack sync)
- Optifine installed on client (required for many 1.12.2 modpacks)
- No stale resource pack — **Options → Resource Packs** → only `Default` active

**"Save being accessed from another location"**
A zombie task is holding the EFS lock. Stop it manually:

```bash
aws ecs list-tasks --cluster mineops-dev-cluster
aws ecs stop-task --cluster mineops-dev-cluster --task <arn>
```

**Server crashes on boot with Forge**
Usually wrong Java version. Verify `profile.json.mc_version` matches your JAR. MC 1.12.2 needs Java 8; MC 1.18+ needs Java 17+.

---

## Branching strategy

| Branch | Purpose |
|---|---|
| `main` | Stable, deployed to prod |
| `develop` | Integration — features merge here |
| `feat/*` | One feature per branch, cut from `develop` |

Flow: `feat/*` → `develop` → `main`.

---

## License

MIT — do whatever you want, attribution appreciated.
