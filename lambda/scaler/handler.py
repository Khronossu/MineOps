import boto3
import json
import os
import socket
import time
import urllib.request
import urllib.error

ecs = boto3.client("ecs", region_name=os.environ["AWS_REGION_NAME"])
ssm = boto3.client("ssm", region_name=os.environ["AWS_REGION_NAME"])
ec2 = boto3.client("ec2", region_name=os.environ["AWS_REGION_NAME"])

CLUSTER = os.environ["ECS_CLUSTER"]
SERVICE = os.environ["ECS_SERVICE"]
MOD_BUCKET = os.environ["MOD_BUCKET"]
CF_ZONE_ID = os.environ["CLOUDFLARE_ZONE_ID"]
CF_TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]


def lambda_handler(event, context):
    action = event.get("action")

    if action == "scale_up":
        return scale_up()
    elif action == "scale_down":
        return scale_down()
    elif action == "switch_profile":
        return switch_profile(event.get("profile"))
    elif action == "status":
        return status()
    else:
        return {"error": f"Unknown action: {action}"}


def scale_up():
    svc = _describe_service()
    if svc["desiredCount"] >= 1:
        ip = _get_task_public_ip()
        return {"status": "already_running", "desiredCount": svc["desiredCount"], "ip": ip}

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)

    # Wait for task to be running and get its public IP
    for _ in range(30):
        time.sleep(10)
        ip = _get_task_public_ip()
        if ip:
            _update_cloudflare_dns(ip)
            return {"status": "scaled_up", "ip": ip, "domain": DOMAIN_NAME}

    return {"status": "scaled_up_no_ip"}


def scale_down():
    svc = _describe_service()
    if svc["desiredCount"] == 0:
        return {"status": "already_stopped"}

    player_count = _get_player_count()
    if player_count > 0:
        return {"status": "players_online", "count": player_count}

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=0)
    return {"status": "scaled_down"}


def switch_profile(profile):
    if not profile:
        return {"error": "profile is required"}

    ssm.put_parameter(
        Name="/minecraft/active-profile",
        Value=profile,
        Overwrite=True,
    )

    ecs.update_service(
        cluster=CLUSTER,
        service=SERVICE,
        forceNewDeployment=True,
    )

    return {"status": "profile_switched", "profile": profile}


def status():
    svc = _describe_service()
    profile = ssm.get_parameter(Name="/minecraft/active-profile")["Parameter"]["Value"]
    ip = _get_task_public_ip()
    return {
        "desiredCount": svc["desiredCount"],
        "runningCount": svc["runningCount"],
        "activeProfile": profile,
        "serverIp": ip,
        "domain": DOMAIN_NAME,
    }


def _describe_service():
    resp = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])
    return resp["services"][0]


def _get_task_public_ip():
    tasks = ecs.list_tasks(cluster=CLUSTER, serviceName=SERVICE, desiredStatus="RUNNING")
    if not tasks["taskArns"]:
        return None

    task_detail = ecs.describe_tasks(cluster=CLUSTER, tasks=tasks["taskArns"])[
        "tasks"
    ][0]

    eni_id = next(
        (
            a["value"]
            for a in task_detail.get("attachments", [{}])[0].get("details", [])
            if a["name"] == "networkInterfaceId"
        ),
        None,
    )
    if not eni_id:
        return None

    eni = ec2.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
    return (
        eni["NetworkInterfaces"][0]
        .get("Association", {})
        .get("PublicIp")
    )


def _get_player_count():
    ip = _get_task_public_ip()
    if not ip:
        print("[rcon] no task IP — treating as 0 players")
        return 0

    rcon_password = ssm.get_parameter(
        Name="/minecraft/rcon-password", WithDecryption=True
    )["Parameter"]["Value"]

    try:
        import mcrcon
        print(f"[rcon] connecting to {ip}:25575")
        with mcrcon.MCRcon(ip, rcon_password, port=25575) as rcon:
            response = rcon.command("list")
            print(f"[rcon] list response: {response!r}")
            import re
            m = re.search(r"There are (\d+)", response)
            count = int(m.group(1)) if m else 0
            print(f"[rcon] player count: {count}")
            return count
    except Exception as e:
        print(f"[rcon] ERROR ({type(e).__name__}): {e} — assuming players online to be safe")
        return 1


def _update_cloudflare_dns(ip):
    headers = {
        "Authorization": f"Bearer {CF_TOKEN}",
        "Content-Type": "application/json",
    }

    # Get existing record ID
    list_url = f"https://api.cloudflare.com/client/v4/zones/{CF_ZONE_ID}/dns_records?type=A&name={DOMAIN_NAME}"
    req = urllib.request.Request(list_url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        records = json.loads(resp.read())["result"]

    payload = json.dumps({"type": "A", "name": DOMAIN_NAME, "content": ip, "ttl": 60, "proxied": False}).encode()

    if records:
        record_id = records[0]["id"]
        url = f"https://api.cloudflare.com/client/v4/zones/{CF_ZONE_ID}/dns_records/{record_id}"
        req = urllib.request.Request(url, data=payload, headers=headers, method="PUT")
    else:
        url = f"https://api.cloudflare.com/client/v4/zones/{CF_ZONE_ID}/dns_records"
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")

    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())
