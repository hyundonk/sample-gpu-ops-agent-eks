"""approve_request Lambda — HIGH 위험 plan의 사람 승인 요청 (무과금 HITL).

SNS로 plan 요약 + task token을 발송하고 즉시 반환 — SFN은 승인자가
send-task-success를 실행할 때까지 무과금 대기한다 (타임아웃 1h).
"""
import json
import os

import boto3

TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
_sns = boto3.client("sns")


def handler(event, context=None):
    plan = event.get("plan", {})
    token = event["task_token"]
    msg = (
        f"[승인 필요 — HIGH] incident: {event.get('incident_id')}\n\n"
        f"scenario: {plan.get('scenario')}\n"
        f"actions: {json.dumps(plan.get('actions', []), ensure_ascii=False, indent=2)}\n"
        f"budget: ${plan.get('budget_est_usd_hr', 0)}/hr\n\n"
        f"report:\n{plan.get('report', '')[:1500]}\n\n"
        f"── 승인 방법 ──\n"
        f"aws stepfunctions send-task-success --region {os.environ.get('AWS_REGION')} \\\n"
        f"  --task-token '{token}' --task-output '{{\"approved\": true}}'\n\n"
        f"거절: send-task-failure --error Rejected 사용 (1시간 무응답 시 자동 실패)"
    )
    _sns.publish(TopicArn=TOPIC_ARN, Subject="[gpu-agent] 승인 요청 (HIGH)", Message=msg)
    return {"notified": True}
