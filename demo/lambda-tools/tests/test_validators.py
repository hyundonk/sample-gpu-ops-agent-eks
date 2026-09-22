"""경계 위반 테스트 — 2층 가드레일(Lambda 코드 재검증)의 완결성 검증.

WP4 완료 기준: "경계 위반 테스트 — 예: patch_nodepool_limits로 gpu-mig 시도 → 거부".
LLM plan이 어떤 값을 내놓아도 화이트리스트 밖이면 반드시 ValidationError.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "shared"))

import pytest

import config
from config import ValidationError


# ── 제어 항목 #1: 게이트 limits ────────────────────────────────────────────
def test_limits_gate_pool_allowed():
    assert config.validate_gate_limits("gpu-od", "2") == 2
    assert config.validate_gate_limits("gpu-od", "0") == 0  # 원복(잠금)


def test_limits_ladder_pool_denied():
    """★ 상시 사다리 불가침 — gpu-mig limits 변경은 코드 레벨에서 거부."""
    with pytest.raises(ValidationError, match="상시 사다리 불가침"):
        config.validate_gate_limits("gpu-mig", "2")


def test_limits_over_max_denied():
    with pytest.raises(ValidationError, match="out of range"):
        config.validate_gate_limits("gpu-od", "3")  # gpuMax=2


def test_limits_nonsense_denied():
    with pytest.raises(ValidationError):
        config.validate_gate_limits("gpu-od", "unlimited")
    with pytest.raises(ValidationError):
        config.validate_gate_limits("gpu-od", "-1")


# ── 제어 항목 #2: consolidateAfter ──────────────────────────────────────────
def test_consolidate_valid():
    assert config.validate_consolidate_after("gpu-mig", "4h") == "4h"
    assert config.validate_consolidate_after("gpu-mig", "30m") == "30m"


def test_consolidate_over_12h_denied():
    with pytest.raises(ValidationError, match="out of range"):
        config.validate_consolidate_after("gpu-mig", "24h")


def test_consolidate_unknown_pool_denied():
    with pytest.raises(ValidationError):
        config.validate_consolidate_after("system", "1h")


def test_consolidate_bad_format_denied():
    with pytest.raises(ValidationError, match="must match"):
        config.validate_consolidate_after("gpu-mig", "Never")


# ── 제어 항목 #3: KEDA ──────────────────────────────────────────────────────
def test_keda_actions():
    assert config.validate_keda("mock-worker", "pause") is None
    assert config.validate_keda("mock-worker", "unpause") is None
    assert config.validate_keda("mock-worker", "set_max", 6) == 6


def test_keda_max_zero_denied():
    """WP2 실측: CRD가 max>=1 강제 — set_max 0은 코드에서도 거부."""
    with pytest.raises(ValidationError, match="out of range"):
        config.validate_keda("mock-worker", "set_max", 0)


def test_keda_max_over_denied():
    with pytest.raises(ValidationError):
        config.validate_keda("mock-worker", "set_max", 99)


def test_keda_unknown_scaledobject_denied():
    with pytest.raises(ValidationError):
        config.validate_keda("other-app", "pause")


# ── 제어 항목 #4: 스택 복구 ──────────────────────────────────────────────────
def test_recover_valid():
    config.validate_recover("relabel", mig_profile="all-2g.48gb")
    config.validate_recover("delete_pod", namespace="gpu-operator")


def test_recover_bad_profile_denied():
    with pytest.raises(ValidationError):
        config.validate_recover("relabel", mig_profile="all-1g.24gb")  # 미검증 프로파일


def test_recover_bad_namespace_denied():
    with pytest.raises(ValidationError):
        config.validate_recover("delete_pod", namespace="kube-system")  # 시스템 NS 차단


# ── 공통: 클러스터 화이트리스트 ────────────────────────────────────────────────
def test_cluster_whitelist():
    config.require_cluster("seoul")
    with pytest.raises(ValidationError):
        config.require_cluster("tokyo")  # Phase 2에서 허용 목록에 추가 예정
    with pytest.raises(ValidationError):
        config.require_cluster("us-east-1")
