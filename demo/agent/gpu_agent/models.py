"""Agent 산출물 스키마 — plan JSON 계약 (v3 §7.3).

Plan은 Agent의 최종 산출물이자 SFN Execute의 입력이다. Agent는 write 도구를
호출할 수 없으므로(Gateway 미등록) 이 스키마가 판단→실행의 유일한 통로다.
actions[].tool/params는 write Lambda의 입력 계약과 1:1이며, 값은 어차피
Lambda 2층 검증 + RBAC 3층을 다시 통과해야 한다 (LLM 출력 불신 원칙).
"""
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class Category(str, Enum):
    """문제 유형 (통합 설계서 §3 — 쉬운 말 명칭과 1:1)."""
    AZ_CAPACITY = "특정 가용영역 부족"
    REGION_CAPACITY = "리전 전체 부족"
    SPOT_INTERRUPTION = "Spot 중단 급증"
    QUOTA = "쿼터 초과"
    GPU_NOT_ADVERTISED = "GPU 미광고"
    PRICE_INVERSION = "가격 역전"
    WORKER_UNHEALTHY = "워커 이상"
    NO_ISSUE = "이상 없음"
    UNKNOWN = "판별 불가"


class Classification(BaseModel):
    category: Category
    confidence: float = Field(ge=0, le=1, description="판정 확신도")
    rationale: str = Field(description="판정 근거 — 관찰된 증거를 인용")
    needs_investigation: bool = Field(
        description="추가 조사가 필요한가 (증거 불충분 시 true)")


class Action(BaseModel):
    """write Lambda 호출 1건 — SFN Execute Parallel의 브랜치가 된다."""
    tool: str = Field(description=(
        "patch_nodepool_limits | patch_consolidate_after | "
        "patch_keda_max | recover_gpu_stack"))
    cluster: str
    params: dict = Field(description="해당 도구의 파라미터 (cluster 제외)")
    reason: str


class Plan(BaseModel):
    scenario: str = Field(description=(
        "OD 잠식 회수 | 노드 보유 연장 | 큐 완충 | 스택 복구 | 리전 확장 | 에스컬레이션 | 조치 불필요"))
    classification: Category
    actions: list[Action] = Field(default_factory=list,
                                  description="에스컬레이션/조치 불필요면 빈 배열")
    risk: str = Field(description="LOW | MEDIUM | HIGH — HIGH는 사람 승인 필요")
    budget_est_usd_hr: float = Field(default=0, description="추가 비용 추정 ($/hr)")
    rollback: str = Field(description="원복 방법과 조건 (모든 변경에 원복 짝 필수)")
    report: str = Field(description="운영자용 요약 — 시도한 판단·근거·기대 효과")
    revert_after_hours: Optional[float] = Field(
        default=None, description="타이머 원복 시각 (시간). 없으면 조건부 원복만")
