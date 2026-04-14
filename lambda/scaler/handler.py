import boto3
import json
import os
import re
import time
import urllib.request

ecs = boto3.client("ecs", region_name=os.environ["AWS_REGION_NAME"])
ssm = boto3.client("ssm", region_name=os.environ["AWS_REGION_NAME"])
ec2 = boto3.client("ec2", region_name=os.environ["AWS_REGION_NAME"])
lambda_client = boto3.client("lambda", region_name=os.environ["AWS_REGION_NAME"])

CLUSTER = os.environ["ECS_CLUSTER"]
SERVICE = os.environ["ECS_SERVICE"]
MOD_BUCKET = os.environ["MOD_BUCKET"]
CF_ZONE_ID = os.environ["CLOUDFLARE_ZONE_ID"]
CF_TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]


def lambda_handler(event, context):
    # HTTP API Gateway event
    if "requestContext" in event and "http" in event.get("requestContext", {}):
        return _http_handler(event, context)

    # Direct invocation
    action = event.get("action")
    if action == "scale_up":
        return scale_up()
    elif action == "scale_down":
        return scale_down()
    elif action == "switch_profile":
        return switch_profile(event.get("profile"))
    elif action == "status":
        return web_status()
    elif action == "wait_and_update_dns":
        return _wait_and_update_dns()
    return {"error": f"Unknown action: {action}"}


def _http_handler(event, context):
    method = event["requestContext"]["http"]["method"]
    path = event["requestContext"]["http"]["path"]

    if method == "OPTIONS":
        return _resp(200, {})
    if path.endswith("/start") and method == "POST":
        return _resp(200, start_async(context))
    if path.endswith("/status") and method == "GET":
        return _resp(200, web_status())
    return _resp(404, {"error": "not found"})


def _resp(code, body):
    return {
        "statusCode": code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        },
        "body": json.dumps(body),
    }


def start_async(context):
    svc = _describe_service()
    if svc["desiredCount"] >= 1:
        return {"status": "already_starting" if svc["runningCount"] == 0 else "already_running"}

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
    lambda_client.invoke(
        FunctionName=context.function_name,
        InvocationType="Event",
        Payload=json.dumps({"action": "wait_and_update_dns"}).encode(),
    )
    return {"status": "starting"}


def _wait_and_update_dns():
    for _ in range(30):
        time.sleep(10)
        ip = _get_task_public_ip()
        if ip:
            _update_cloudflare_dns(ip)
            return {"status": "dns_updated", "ip": ip}
    return {"status": "timed_out"}


def scale_up():
    svc = _describe_service()
    if svc["desiredCount"] >= 1:
        ip = _get_task_public_ip()
        return {"status": "already_running", "desiredCount": svc["desiredCount"], "ip": ip}

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
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
    ssm.put_parameter(Name="/minecraft/active-profile", Value=profile, Overwrite=True)
    ecs.update_service(cluster=CLUSTER, service=SERVICE, forceNewDeployment=True)
    return {"status": "profile_switched", "profile": profile}


def _get_active_profile():
    try:
        return ssm.get_parameter(Name="/minecraft/active-profile")["Parameter"]["Value"]
    except Exception:
        return "unknown"


def web_status():
    svc = _describe_service()
    desired = svc["desiredCount"]
    running = svc["runningCount"]
    profile = _get_active_profile()

    if desired == 0:
        return {"state": "offline", "players": 0, "domain": DOMAIN_NAME, "profile": profile}
    if running == 0:
        return {"state": "booting", "players": 0, "domain": DOMAIN_NAME, "profile": profile}

    ip = _get_task_public_ip()
    if not ip:
        return {"state": "booting", "players": 0, "domain": DOMAIN_NAME, "profile": profile}

    try:
        rcon_password = ssm.get_parameter(
            Name="/minecraft/rcon-password", WithDecryption=True
        )["Parameter"]["Value"]
        import mcrcon
        with mcrcon.MCRcon(ip, rcon_password, port=25575) as rcon:
            response = rcon.command("list")
            m = re.search(r"There are (\d+)", response)
            count = int(m.group(1)) if m else 0
            return {"state": "online", "players": count, "domain": DOMAIN_NAME, "profile": profile}
    except Exception:
        return {"state": "booting", "players": 0, "domain": DOMAIN_NAME, "profile": profile}


def _describe_service():
    resp = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])
    return resp["services"][0]


def _get_task_public_ip():
    tasks = ecs.list_tasks(cluster=CLUSTER, serviceName=SERVICE, desiredStatus="RUNNING")
    if not tasks["taskArns"]:
        return None

    task_detail = ecs.describe_tasks(cluster=CLUSTER, tasks=tasks["taskArns"])["tasks"][0]
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
    return eni["NetworkInterfaces"][0].get("Association", {}).get("PublicIp")


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
            m = re.search(r"There are (\d+)", response)
            count = int(m.group(1)) if m else 0
            print(f"[rcon] player count: {count}")
            return count
    except Exception as e:
        print(f"[rcon] ERROR ({type(e).__name__}): {e} — assuming players online to be safe")
        return 1


def _update_cloudflare_dns(ip):
    headers = {"Authorization": f"Bearer {CF_TOKEN}", "Content-Type": "application/json"}
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
