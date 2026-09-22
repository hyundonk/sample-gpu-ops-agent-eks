"""판단 파이프라인 — classify → investigate → plan (v3 §7.2의 Graph 의미론).

GraphBuilder 대신 결정론적 순차 코드로 구현한 이유:
  ① "조사 없이 액션 불가"가 코드 구조로 강제됨 (plan 노드에는 도구가 없음)
  ② read 도구는 investigate 노드에만 바인딩 — 다른 노드는 도구 표면 자체가 없음
  ③ 단계 전이가 LLM 판단이 아니라 코드 — 파이프라인 자체는 비결정성이 없음
"""
import json
import logging
import os

from strands import Agent
from strands.models.bedrock import BedrockModel

from gpu_agent import prompts
from gpu_agent.mcp_client import create_mcp_client
from gpu_agent.models import Classification, Plan

log = logging.getLogger("gpu-agent")

MODEL_ID = os.environ.get("MODEL_ID", "global.anthropic.claude-sonnet-4-6")


def _model() -> BedrockModel:
    # prompt caching: 시스템 프롬프트·도구 스키마 캐시 (참조 프로젝트 패턴 —
    # 반복 인시던트·posture 주기 호출에서 토큰 ~90% 절감)
    return BedrockModel(model_id=MODEL_ID, cache_prompt="default", cache_tools="default")


def run_pipeline(event: dict) -> dict:
    """인시던트/posture 이벤트 → plan JSON. SFN Investigate가 이 결과로 재개된다."""
    context_bundle = json.dumps(event.get("context_bundle", {}), ensure_ascii=False)
    alarm = json.dumps(event.get("alarm", {}), ensure_ascii=False)

    # ── 1. classify (도구 없음 — 번들 증거만으로 1차 판정) ──────────────────
    classifier = Agent(model=_model(), system_prompt=prompts.CLASSIFY_SYSTEM)
    classification = classifier.structured_output(
        Classification,
        f"알람:\n{alarm}\n\n컨텍스트 번들:\n{context_bundle}")
    log.info("classify: %s (conf=%.2f) investigate=%s",
             classification.category.value, classification.confidence,
             classification.needs_investigation)

    # ── 2. investigate (read 도구는 이 노드에만 바인딩) ─────────────────────
    evidence = "(조사 생략 — 분류 확신 충분)"
    if classification.needs_investigation or classification.confidence < 0.8:
        # 주의: with 블록 금지 — Agent(tools=[mcp])가 세션 수명을 자체 관리하므로
        # 먼저 열면 "client session is currently running" 충돌 (실측 2026-09-22)
        mcp = create_mcp_client()
        investigator = Agent(model=_model(),
                             system_prompt=prompts.INVESTIGATE_SYSTEM,
                             tools=[mcp])
        result = investigator(
            f"1차 분류: {classification.category.value} "
            f"(근거: {classification.rationale})\n"
            f"알람: {alarm}\n이 가설을 확증/반증할 증거를 수집하세요. "
            f"cluster는 'seoul'입니다.")
        evidence = str(result)
    log.info("investigate done (%d chars)", len(evidence))

    # ── 3. plan (도구 없음 — 산출물은 plan JSON뿐) ──────────────────────────
    planner = Agent(model=_model(), system_prompt=prompts.PLAN_SYSTEM)
    plan = planner.structured_output(
        Plan,
        f"분류: {classification.category.value} (확신도 {classification.confidence})\n"
        f"분류 근거: {classification.rationale}\n\n조사 증거:\n{evidence}\n\n"
        f"알람 원문:\n{alarm}")
    log.info("plan: scenario=%s actions=%d risk=%s",
             plan.scenario, len(plan.actions), plan.risk)

    return {
        "classification": classification.model_dump(mode="json"),
        "evidence_summary": evidence[:2000],
        "plan": plan.model_dump(mode="json"),
    }
