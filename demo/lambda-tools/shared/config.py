"""도구 공통 설정·검증 — 3중 가드레일의 2층 (Lambda 코드 재검증).

LLM(plan JSON)의 출력을 신뢰하지 않는다: 모든 write 도구는 실행 전에
여기 화이트리스트·상한으로 파라미터를 재검증한다 (1층 AgentCore Policy,
3층 K8s RBAC와 독립적으로 동작).

값은 Git 소유(통합 설계서 §5.1) — 상한 변경은 코드리뷰를 거친다.
데모 상한은 프로덕션 값과 같은 '진짜' 강제력으로 둔다 (가드레일 자체가 검증 대상).
"""
import re

# ── 클러스터 (Phase 2에서 tokyo/mumbai 추가 — env CLUSTERS와 일치해야 함) ────
ALLOWED_CLUSTERS = {"seoul"}

# ── NodePool ────────────────────────────────────────────────────────────────
GATE_POOLS = {"gpu-od"}                          # limits 변경 허용 = 게이트 풀만
LADDER_POOLS = {"gpu-mig", "gpu-g6e", "gpu-od"}  # consolidateAfter 허용 범위
GPU_LIMIT_MAX = {"gpu-od": 2}                    # 개방 상한 (광고 슬롯 기준 — 실측 2026-09-21)
CONSOLIDATE_MAX_MINUTES = 12 * 60                # 노드 보유 연장 상한 12h

# ── KEDA ────────────────────────────────────────────────────────────────────
WORKER_NAMESPACE = "inference"
ALLOWED_SCALEDOBJECTS = {"mock-worker"}
KEDA_MAX_RANGE = (1, 8)                          # CRD가 max>=1 강제 (실측 2026-09-22)
PAUSE_ANNOTATION = "autoscaling.keda.sh/paused-replicas"

# ── 스택 복구 ─────────────────────────────────────────────────────────────────
ALLOWED_MIG_PROFILES = {"all-2g.48gb"}
POD_DELETE_NAMESPACES = {"inference", "gpu-operator"}

_DURATION_RE = re.compile(r"^(\d+)(m|h)$")


class ValidationError(Exception):
    """가드레일 위반 — 호출자(SFN)가 실패로 인지하도록 예외로 전파."""


def require_cluster(cluster: str) -> None:
    if cluster not in ALLOWED_CLUSTERS:
        raise ValidationError(f"cluster '{cluster}' not allowed (allowed: {sorted(ALLOWED_CLUSTERS)})")


def validate_gate_limits(name: str, gpu: str) -> int:
    """제어 항목 #1: 게이트 풀 limits — 게이트 풀만, 상한 이내만."""
    if name not in GATE_POOLS:
        raise ValidationError(
            f"limits patch on '{name}' denied — only gate pools {sorted(GATE_POOLS)} "
            "(상시 사다리 불가침)")
    try:
        val = int(gpu)
    except (TypeError, ValueError):
        raise ValidationError(f"gpu must be an integer string, got {gpu!r}")
    if not 0 <= val <= GPU_LIMIT_MAX[name]:
        raise ValidationError(f"gpu={val} out of range 0..{GPU_LIMIT_MAX[name]} for '{name}'")
    return val


def validate_consolidate_after(name: str, duration: str) -> str:
    """제어 항목 #2: 사다리 풀만, 12h 이내, '30m'/'4h' 형식."""
    if name not in LADDER_POOLS:
        raise ValidationError(f"nodepool '{name}' not in ladder {sorted(LADDER_POOLS)}")
    m = _DURATION_RE.match(str(duration))
    if not m:
        raise ValidationError(f"duration {duration!r} must match <n>m or <n>h")
    minutes = int(m.group(1)) * (60 if m.group(2) == "h" else 1)
    if not 1 <= minutes <= CONSOLIDATE_MAX_MINUTES:
        raise ValidationError(f"duration {duration} out of range 1m..{CONSOLIDATE_MAX_MINUTES // 60}h")
    return duration


def validate_keda(name: str, action: str, max_value=None) -> int | None:
    """제어 항목 #3: pause/unpause/set_max — max는 허용 범위만."""
    if name not in ALLOWED_SCALEDOBJECTS:
        raise ValidationError(f"scaledobject '{name}' not allowed")
    if action not in {"pause", "unpause", "set_max"}:
        raise ValidationError(f"action '{action}' not in pause|unpause|set_max")
    if action == "set_max":
        try:
            val = int(max_value)
        except (TypeError, ValueError):
            raise ValidationError(f"max must be an integer, got {max_value!r}")
        lo, hi = KEDA_MAX_RANGE
        if not lo <= val <= hi:
            raise ValidationError(f"max={val} out of range {lo}..{hi}")
        return val
    return None


def validate_recover(action: str, mig_profile=None, namespace=None) -> None:
    """제어 항목 #4: 라벨 원복은 프로파일 화이트리스트, Pod 삭제는 지정 NS만."""
    if action not in {"relabel", "delete_pod"}:
        raise ValidationError(f"action '{action}' not in relabel|delete_pod")
    if action == "relabel" and mig_profile not in ALLOWED_MIG_PROFILES:
        raise ValidationError(f"mig_profile {mig_profile!r} not in {sorted(ALLOWED_MIG_PROFILES)}")
    if action == "delete_pod" and namespace not in POD_DELETE_NAMESPACES:
        raise ValidationError(f"namespace {namespace!r} not in {sorted(POD_DELETE_NAMESPACES)}")
