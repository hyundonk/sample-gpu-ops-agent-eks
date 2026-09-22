"""report Lambda — 리포트 발송 + 감사 기록 + 원복 타이머 등록 (SFN 종단).

원복은 결정론 역산 (Agent 재개입 불필요 — §7.1):
  patch_nodepool_limits(gpu=N)  → 역: gpu="0" (게이트 잠금)
  patch_keda_max(pause)         → 역: unpause  /  (unpause) → pause
  patch_keda_max(set_max=N)     → 역: set_max=기본값 6
  patch_consolidate_after(d)    → 역: "30m" (평시값)
  recover_gpu_stack             → 원복 없음 (복구 자체가 정상화)
Scheduler 일회성(at, 실행 후 자동 삭제) → execute_action 디스패처 재사용
(원복도 실행과 같은 가드레일을 통과한다).
"""
import datetime
import json
import os

import boto3

TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
DDB_TABLE = os.environ["DDB_TABLE"]
EXECUTE_LAMBDA_ARN = os.environ["EXECUTE_LAMBDA_ARN"]
SCHEDULER_ROLE_ARN = os.environ["SCHEDULER_ROLE_ARN"]

_sns = boto3.client("sns")
_ddb = boto3.client("dynamodb")
_scheduler = boto3.client("scheduler")


def _revert_action(action: dict) -> dict | None:
    tool, params = action["tool"], action.get("params", {})
    if tool == "patch_nodepool_limits":
        return {"tool": tool, "cluster": action["cluster"],
                "params": {"name": params.get("name", "gpu-od"), "gpu": "0"}}
    if tool == "patch_keda_max":
        act = params.get("action")
        inverse = {"pause": {"action": "unpause"},
                   "unpause": {"action": "pause"},
                   "set_max": {"action": "set_max", "max": 6}}.get(act)
        if inverse:
            return {"tool": tool, "cluster": action["cluster"],
                    "params": {"name": params.get("name", "mock-worker"), **inverse}}
    if tool == "patch_consolidate_after":
        return {"tool": tool, "cluster": action["cluster"],
                "params": {"name": params.get("name"), "duration": "30m"}}
    return None  # recover_gpu_stack 등 — 원복 불필요


def handler(event, context=None):
    incident = event.get("incident_id", "unknown")
    plan = (event.get("agent") or {}).get("plan", {})
    shadow = event.get("shadow_mode", True)
    executed = event.get("exec_results", [])
    error = event.get("error")

    status = ("FAILED" if error else
              "SHADOW" if shadow else
              "EXECUTED" if executed else "NO_ACTION")

    # 원복 타이머 등록 (실행됐고 revert_after_hours가 있을 때)
    revert_note = ""
    hours = plan.get("revert_after_hours")
    if status == "EXECUTED" and hours:
        reverts = [r for a in plan.get("actions", []) if (r := _revert_action(a))]
        if reverts:
            at = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(hours=float(hours)))
            for i, rv in enumerate(reverts):
                _scheduler.create_schedule(
                    Name=f"revert-{incident[:50]}-{i}",
                    ScheduleExpression=f"at({at.strftime('%Y-%m-%dT%H:%M:%S')})",
                    FlexibleTimeWindow={"Mode": "OFF"},
                    ActionAfterCompletion="DELETE",
                    Target={"Arn": EXECUTE_LAMBDA_ARN,
                            "RoleArn": SCHEDULER_ROLE_ARN,
                            "Input": json.dumps({"action": rv}, ensure_ascii=False),
                            "RetryPolicy": {"MaximumRetryAttempts": 3}})
            revert_note = f"원복 {len(reverts)}건 등록 (+{hours}h)"

    # 감사 기록
    _ddb.update_item(
        TableName=DDB_TABLE,
        Key={"incident_key": {"S": event.get("incident_key", incident)}},
        UpdateExpression="SET #s = :s, plan_json = :p, report_at = :t",
        ExpressionAttributeNames={"#s": "state"},
        ExpressionAttributeValues={
            ":s": {"S": status},
            ":p": {"S": json.dumps(plan, ensure_ascii=False)[:35000]},
            ":t": {"S": datetime.datetime.now(datetime.timezone.utc).isoformat()}})

    # 리포트 발송
    subject = f"[gpu-agent] {status} — {plan.get('scenario', 'n/a')} ({incident[:40]})"
    body = (f"incident: {incident}\nstatus: {status} (shadow={shadow})\n"
            f"classification: {plan.get('classification')}\n"
            f"scenario: {plan.get('scenario')} / risk: {plan.get('risk')}\n"
            f"actions: {json.dumps(plan.get('actions', []), ensure_ascii=False)}\n"
            f"{revert_note}\n"
            f"{'error: ' + json.dumps(error)[:500] if error else ''}\n\n"
            f"{plan.get('report', '')[:1800]}")
    _sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:99], Message=body)
    print(f"REPORT incident={incident} status={status} {revert_note}")
    return {"status": status, "revert": revert_note}
