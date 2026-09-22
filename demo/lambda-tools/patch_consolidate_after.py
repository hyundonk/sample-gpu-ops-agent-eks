"""write 도구 ② patch_consolidate_after — 확보 노드 보유 연장 (제어 항목 #2).

입력: {"cluster": "seoul", "name": "gpu-mig", "duration": "4h"}
경계: 사다리 풀만 + 최대 12h. fail-safe 방향(회수 지연)이라 위험도 최저.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "shared"))

import config
import k8s_client


def handler(event, context=None):
    cluster, name = event["cluster"], event["name"]
    config.require_cluster(cluster)
    duration = config.validate_consolidate_after(name, event["duration"])

    path = f"/apis/karpenter.sh/v1/nodepools/{name}"
    before = k8s_client.get(cluster, path)["spec"].get("disruption", {}).get("consolidateAfter")
    after_obj = k8s_client.merge_patch(cluster, path,
        {"spec": {"disruption": {"consolidateAfter": duration}}})
    after = after_obj["spec"].get("disruption", {}).get("consolidateAfter")
    print(f"AUDIT patch_consolidate_after cluster={cluster} pool={name} {before} -> {after}")
    return {"ok": True, "tool": "patch_consolidate_after", "cluster": cluster,
            "name": name, "before": before, "after": after}
