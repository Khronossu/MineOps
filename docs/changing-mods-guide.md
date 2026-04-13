# Changing Mods Guide

How to switch the server to a different modpack — including when the new pack requires a different Minecraft version.

The Docker image already bundles **Java 8** (for MC ≤ 1.16) and **Java 21** (for MC ≥ 1.17). `docker/start.sh` auto-selects the right Java based on `profile.json.mc_version`, so you **do not need to rebuild the image** for version changes.

---

## 1. Authenticate to AWS

From WSL (or any shell with AWS CLI):

```bash
aws configure
```

You'll be prompted for:

```
AWS Access Key ID [None]:      AKIA...
AWS Secret Access Key [None]:  <your-secret>
Default region name [None]:    ap-southeast-1
Default output format [None]:  json
```

Verify you're in the right account:

```bash
aws sts get-caller-identity
```

The `Account` field should match the MineOps AWS account.

---

## 2. Prepare the new modpack locally

Create a folder under `mods/<profile-name>/`:

```
mods/skyfactory/
├── server.jar              # server JAR matching the MC version and loader
├── server.properties       # must include enable-rcon=true and rcon.password
├── profile.json            # metadata — see below
├── mod1.jar
├── mod2.jar
└── config/                 # optional; synced if present
```

### `profile.json` format

```json
{
  "mc_version": "1.20.1",
  "loader": "forge",
  "loader_version": "47.2.0"
}
```

- `mc_version` — determines Java version (≤ 1.16 → Java 8; ≥ 1.17 → Java 21)
- `loader` — `forge`, `fabric`, `neoforge`, or `vanilla`
- `loader_version` — only used for Forge library sync

### `server.properties` essentials

At minimum ensure these lines exist:

```properties
enable-rcon=true
rcon.port=25575
rcon.password=<same-as-SSM-parameter>
```

Without these, the Lambda cannot detect online players and will shut the server down while you're playing.

---

## 3. Upload to S3

```bash
aws s3 sync mods/skyfactory/ s3://mineops-mods-dev/minecraft-mods/skyfactory/
```

This uploads every file in the folder to `s3://<bucket>/minecraft-mods/<profile>/`.

### For Forge profiles

If the new profile is Forge, you may also need to upload the Forge libraries and vanilla server jar once to the shared `setup/` prefix:

```bash
aws s3 sync <local-forge-libraries>/ s3://mineops-mods-dev/setup/libraries/
aws s3 cp minecraft_server.1.20.1.jar s3://mineops-mods-dev/setup/
```

`start.sh` will pull these on boot for any Forge profile.

---

## 4. Switch the active profile

```bash
aws lambda invoke --function-name mineops-dev-scaler \
  --payload '{"action":"switch_profile","profile":"skyfactory"}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

This:
1. Updates SSM parameter `/minecraft/active-profile`
2. Triggers an ECS force-new-deployment so the next task reads the new profile

On boot, the container will:
- Sync `s3://<bucket>/minecraft-mods/skyfactory/` → `/minecraft/mods/` (with `--delete`, so old mods are removed)
- Sync `config/`, `scripts/`, `resources/`, `structures/` if present
- Copy `server.properties` from S3
- Pick the right Java version
- Start the server

---

## 5. Connect

Open the web panel at `play.purinboonpetch.com` (the control panel), click **Boot Server** if offline, wait ~3 minutes, then connect via Minecraft to:

```
play.purinboonpetch.com:25565
```

The Cloudflare A record auto-updates to the new task's public IP on every boot.

---

## Notes

### World persistence

`/minecraft/world/` is **never** wiped by a profile switch — only `/minecraft/mods/` is. Your world survives across profile changes.

If you want per-profile worlds, the recommended approach is to use `/minecraft/world-{profile}/` on EFS and symlink `/minecraft/world` → `/minecraft/world-{active-profile}/` in `start.sh`. Not currently implemented.

### When you *do* need to rebuild the Docker image

Only when the new MC version requires a Java version not already in the image. Currently bundled:

- Java 8 (for MC ≤ 1.16)
- Java 21 (for MC ≥ 1.17)

This covers every mainstream MC version. If you ever need Java 11 or 17 specifically, add it to `docker/Dockerfile` and push a new image to ECR.

### Testing locally first

Before uploading a ~2 GB modpack just to find a crash, test it locally with the same JAR and mods. If it boots on your machine, it'll boot on Fargate.
