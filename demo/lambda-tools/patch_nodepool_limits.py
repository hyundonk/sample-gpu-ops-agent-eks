"""write 도구 ① patch_nodepool_limits — 게이트 개폐 (제어 항목 #1).

입력: {"cluster": "seoul", "name": "gpu-od", "gpu": "2"}
경계: 게이트 풀만(상시 사다리 불가침 — 코드 강제) + 상한 이내 + RBAC.
Agent는 이 Lambda를 호출하지 않는다 — SFN Execute 전용 (v3 §7.3).
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "shared"))

import config
import k8s_client


def handler(event, context=None):
    cluster, name = event["cluster"], event["name"]
    config.require_cluster(cluster)
    gpu = config.validate_gate_limits(name, event["gpu"])  # ← 2층 가드레일

    path = f"/apis/karpenter.sh/v1/nodepools/{name}"
    before = k8s_client.get(cluster, path)["spec"].get("limits", {}).get("nvidia.com/gpu")
    after_obj = k8s_client.merge_patch(cluster, path,
        {"spec": {"limits": {"nvidia.com/gpu": str(gpu)}}})
    after = after_obj["spec"].get("limits", {}).get("nvidia.com/gpu")
    print(f"AUDIT patch_nodepool_limits cluster={cluster} pool={name} {before} -> {after}")
    return {"ok": True, "tool": "patch_nodepool_limits", "cluster": cluster,
            "name": name, "before": before, "after": after}
