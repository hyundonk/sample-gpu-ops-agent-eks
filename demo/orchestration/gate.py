"""Gate Lambda — 결정론 방어선 (v3 §7.2 경로 A의 입구).

SQS(incidents) 이벤트 → 중복 제거·쿨다운 → 컨텍스트 번들 → SFN StartExecution.
Agent(LLM)에 도달하기 전의 모든 결정론적 필터가 여기 모인다:
  - incident key = alarmName (동일 알람의 재전이는 쿨다운 내 무시)
  - DynamoDB 조건부 쓰기가 유일한 진입 티켓 (경합 안전)
  - SFN 실행명 = incident_id — 실행명 유일성이 멱등성을 이중 보장
"""
import datetime
import json
import os
import re
import time

import boto3

DDB_TABLE = os.environ["DDB_TABLE"]
SFN_ARN = os.environ["SFN_ARN"]
SHADOW_MODE = os.environ.get("SHADOW_MODE", "true").lower() == "true"
COOLDOWN_SEC = int(os.environ.get("COOLDOWN_SEC", "1800"))
VERIFY_WAIT = int(os.environ.get("VERIFY_WAIT_SEC", "600"))
CLUSTER = os.environ.get("CLUSTER_NAME", "gpu-agent-demo-seoul")

_ddb = boto3.client("dynamodb")
_sfn = boto3.client("stepfunctions")
_cw = boto3.client("cloudwatch")


def _context_bundle() -> dict:
    """Agent 조사 부담을 줄이는 사전 수집 (최근 30분 핵심 메트릭)."""
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(minutes=30)
    bundle = {}
    for name in ["QueueDepth", "PendingWorkers", "GpuNotAdvertisedNodes"]:
        try:
            r = _cw.get_metric_statistics(
                Namespace="GpuAgentDemo", MetricName=name,
                Dimensions=[{"Name": "Cluster", "Value": CLUSTER}],
                StartTime=start, EndTime=end, Period=300, Statistics=["Average"])
            pts = sorted(r["Datapoints"], key=lambda d: d["Timestamp"])
            bundle[name] = [round(p["Average"], 1) for p in pts]
        except Exception as e:  # noqa: BLE001
            bundle[name] = f"collection failed: {e}"
    return bundle


def handler(event, context=None):
    started = []
    for record in event.get("Records", []):
        detail = json.loads(record["body"]).get("detail", {})
        alarm_name = detail.get("alarmName", "unknown")
        state = detail.get("state", {}).get("value")
        if state != "ALARM":
            continue

        now = int(time.time())
        incident_id = re.sub(r"[^a-zA-Z0-9-_]", "-", f"{alarm_name}-{now}")[:78]

        # 쿨다운 게이트: 동일 알람 클래스의 활성/최근 인시던트가 있으면 스킵
        try:
            _ddb.put_item(
                TableName=DDB_TABLE,
                Item={
                    "incident_key": {"S": alarm_name},
                    "incident_id": {"S": incident_id},
                    "started_at": {"N": str(now)},
                    "cooldown_until": {"N": str(now + COOLDOWN_SEC)},
                    "state": {"S": "STARTED"},
                },
                # 항목이 없거나 쿨다운이 끝났을 때만 통과
                ConditionExpression="attribute_not_exists(incident_key) OR cooldown_until < :now",
                ExpressionAttributeValues={":now": {"N": str(now)}},
            )
        except _ddb.exceptions.ConditionalCheckFailedException:
            print(f"GATE incident={alarm_name} suppressed (cooldown)")
            continue

        sfn_input = {
            "incident_id": incident_id,
            "incident_key": alarm_name,
            "alarm": detail,
            "context_bundle": _context_bundle(),
            "shadow_mode": SHADOW_MODE,
            "verify_wait": VERIFY_WAIT,
        }
        _sfn.start_execution(stateMachineArn=SFN_ARN, name=incident_id,
                             input=json.dumps(sfn_input, ensure_ascii=False))
        print(f"GATE incident={incident_id} started (shadow={SHADOW_MODE})")
        started.append(incident_id)
    return {"started": started}
