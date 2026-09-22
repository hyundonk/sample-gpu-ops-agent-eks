"""AgentCore Runtime entrypoint — v3 §7.2의 비동기 계약 구현.

두 호출 경로:
  A. SFN 경로 (task_token 있음): 백그라운드로 파이프라인 시작 후 즉시
     "accepted" 반환 → SFN은 무과금 대기 → 완료 시 SendTaskSuccess(plan).
  C. 운영자 경로 (token 없음): 동기 실행 후 결과 반환 (Shadow 검증·수동 조사).

콜드스타트 요건: 모듈 로드에서 무거운 초기화 금지 조건이지만, 파이프라인은
호출별 Agent를 생성하므로(짧은 세션) 로드 시점 작업이 원래 가볍다.
"""
import asyncio
import json
import logging
import os

import boto3
from bedrock_agentcore import BedrockAgentCoreApp

from gpu_agent.pipeline import run_pipeline

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("entrypoint")

app = BedrockAgentCoreApp()
_sfn = boto3.client("stepfunctions", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))


def _run_and_callback(event: dict, token: str) -> None:
    incident = event.get("incident_id", "unknown")
    try:
        result = run_pipeline(event)
        _sfn.send_task_success(taskToken=token, output=json.dumps(result, ensure_ascii=False))
        log.info("incident=%s plan delivered via SendTaskSuccess", incident)
    except Exception as e:  # noqa: BLE001 — 침묵 실패 방지: SFN에 명시적 실패 전달
        log.exception("incident=%s pipeline failed: %s", incident, e)
        try:
            _sfn.send_task_failure(taskToken=token, error="PipelineError", cause=str(e)[:250])
        except Exception as cb_err:  # noqa: BLE001
            # 토큰 만료 등 — SFN Timeout이 최후 방어. 침묵하지 않고 기록만 남긴다
            log.warning("incident=%s task_failure callback also failed: %s", incident, cb_err)


@app.entrypoint
async def invoke(payload, context=None):
    incident = payload.get("incident_id", "manual")
    token = payload.get("task_token")

    if token:  # 경로 A — 비동기 (즉시 accepted, SFN은 무과금 대기)
        log.info("incident=%s async invocation accepted", incident)
        asyncio.get_event_loop().run_in_executor(None, _run_and_callback, payload, token)
        return {"status": "accepted", "incident_id": incident}

    # 경로 C — 동기 (운영자/Shadow 검증)
    log.info("incident=%s sync invocation", incident)
    return run_pipeline(payload)


if __name__ == "__main__":
    app.run()
