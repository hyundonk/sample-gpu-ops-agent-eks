"""execute_action Lambda — plan.actions[] 1건을 write 도구로 디스패치.

SFN Execute(Map)의 iterator. Agent는 write 도구를 호출할 수 없으므로(v3 §7.3)
이 dispatcher가 plan JSON의 action을 검증된 write Lambda로 전달한다.
원복(Scheduler)도 같은 경로를 재사용한다 — 실행과 원복이 같은 가드레일 통과.
"""
import json
import os

import boto3

TOOL_PREFIX = os.environ["TOOL_PREFIX"]  # 예: gpu-agent-demo-seoul-tool
ALLOWED_TOOLS = {"patch_nodepool_limits", "patch_consolidate_after",
                 "patch_keda_max", "recover_gpu_stack"}
_lambda = boto3.client("lambda")


def handler(event, context=None):
    action = event["action"]
    tool = action["tool"]
    if tool not in ALLOWED_TOOLS:  # 1차 화이트리스트 (도구 Lambda의 2층 검증과 별개)
        raise ValueError(f"tool '{tool}' not in write whitelist {sorted(ALLOWED_TOOLS)}")

    fn = f"{TOOL_PREFIX}-{tool.replace('_', '-')}"
    payload = {"cluster": action["cluster"], **action.get("params", {})}
    resp = _lambda.invoke(FunctionName=fn,
                          Payload=json.dumps(payload, ensure_ascii=False).encode())
    body = json.loads(resp["Payload"].read())
    if resp.get("FunctionError"):
        # 도구의 가드레일 거부(ValidationError 등)를 SFN 실패로 전파
        raise RuntimeError(f"{tool} rejected: {body.get('errorMessage', body)}")
    print(f"EXECUTE {tool} {payload} -> {body}")
    return body
