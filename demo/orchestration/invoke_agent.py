"""invoke_agent Lambda — SFN task-token을 Agent에 전달하는 콜백 브리지.

SFN의 SDK 통합은 waitForTaskToken을 지원하지 않으므로, 이 Lambda가
lambda:invoke.waitForTaskToken으로 호출되어 토큰을 payload에 실어
AgentCore Runtime을 비동기 호출하고 즉시 반환한다 (v3 §7.2 경로 A).
"""
import json
import os
import uuid

import boto3

RUNTIME_ARN = os.environ["AGENT_RUNTIME_ARN"]
_ac = boto3.client("bedrock-agentcore")


def handler(event, context=None):
    payload = {
        "incident_id": event["incident_id"],
        "task_token": event["task_token"],
        "alarm": event.get("alarm", {}),
        "context_bundle": event.get("context_bundle", {}),
    }
    # runtimeSessionId 최소 33자 제약 (실측) — uuid 접미로 충족
    session_id = f"{event['incident_id'][:40]}-{uuid.uuid4()}"
    resp = _ac.invoke_agent_runtime(
        agentRuntimeArn=RUNTIME_ARN,
        runtimeSessionId=session_id,
        payload=json.dumps(payload, ensure_ascii=False).encode(),
    )
    ack = resp["response"].read().decode()[:200]
    print(f"invoke_agent incident={event['incident_id']} ack={ack}")
    return {"accepted": True}  # SFN은 이 반환값이 아니라 SendTaskSuccess를 기다림
