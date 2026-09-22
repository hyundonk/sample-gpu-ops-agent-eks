"""write 도구 ③ patch_keda_max — 수요 완충 + 리전 게이트 (제어 항목 #3).

입력: {"cluster": "seoul", "name": "mock-worker",
       "action": "pause" | "unpause" | "set_max", "max"?: 6}

WP2 실측 반영: KEDA CRD가 maxReplicaCount >= 1을 강제하므로
  게이트 닫힘 = paused-replicas="0" 어노테이션, 개방 = 어노테이션 제거.
  수요 완충은 set_max (1..8 범위).
주의: pause(0) 시 기존 워커도 종료됨 — 워커의 graceful shutdown re-push가
  작업 손실을 방지한다 (WP2 검증 완료).
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "shared"))

import config
import k8s_client


def handler(event, context=None):
    cluster, name, action = event["cluster"], event["name"], event["action"]
    config.require_cluster(cluster)
    max_val = config.validate_keda(name, action, event.get("max"))

    path = (f"/apis/keda.sh/v1alpha1/namespaces/{config.WORKER_NAMESPACE}"
            f"/scaledobjects/{name}")
    cur = k8s_client.get(cluster, path)
    before = {
        "paused": cur["metadata"].get("annotations", {}).get(config.PAUSE_ANNOTATION),
        "max": cur["spec"].get("maxReplicaCount"),
    }

    if action == "pause":
        body = {"metadata": {"annotations": {config.PAUSE_ANNOTATION: "0"}}}
    elif action == "unpause":
        body = {"metadata": {"annotations": {config.PAUSE_ANNOTATION: None}}}  # merge-patch null = 제거
    else:  # set_max
        body = {"spec": {"maxReplicaCount": max_val}}

    after_obj = k8s_client.merge_patch(cluster, path, body)
    after = {
        "paused": after_obj["metadata"].get("annotations", {}).get(config.PAUSE_ANNOTATION),
        "max": after_obj["spec"].get("maxReplicaCount"),
    }
    print(f"AUDIT patch_keda_max cluster={cluster} so={name} action={action} {before} -> {after}")
    return {"ok": True, "tool": "patch_keda_max", "cluster": cluster,
            "name": name, "action": action, "before": before, "after": after}
