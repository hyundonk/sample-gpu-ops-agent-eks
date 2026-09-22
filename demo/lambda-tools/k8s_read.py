"""read 도구 ① k8s_read — 확보 실패/워커 이상 진단의 주 근거.

입력: {"cluster": "seoul", "resource": "nodeclaims|nodepools|nodes|pods|events", "namespace"?}
출력: LLM 소비용으로 요약된 리스트 (원본 JSON은 수십 KB — 토큰 절약 필수).

핵심: nodeclaims의 조건 메시지에 ICE/쿼터 에러 코드가 그대로 담긴다
(CloudTrail 제외 결정의 근거 — 통합 설계서 §7.3).
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "shared"))

import config
import k8s_client

RESOURCE_PATHS = {
    "nodeclaims": "/apis/karpenter.sh/v1/nodeclaims",
    "nodepools": "/apis/karpenter.sh/v1/nodepools",
    "nodes": "/api/v1/nodes?labelSelector=node-role=gpu",
    "pods": "/api/v1/namespaces/{ns}/pods",
    "events": "/api/v1/namespaces/default/events?limit=30",
}


def _sum_nodeclaim(i):
    conds = {c["type"]: c for c in i.get("status", {}).get("conditions", [])}
    launched = conds.get("Launched", {})
    return {
        "name": i["metadata"]["name"],
        "nodepool": i["metadata"].get("labels", {}).get("karpenter.sh/nodepool"),
        "type": i.get("status", {}).get("nodeName") and i["metadata"].get("labels", {}).get("node.kubernetes.io/instance-type"),
        "capacity_type": i["metadata"].get("labels", {}).get("karpenter.sh/capacity-type"),
        "ready": conds.get("Ready", {}).get("status"),
        "launched": launched.get("status"),
        # ★ 에러 코드가 여기 담긴다 (예: UnfulfillableCapacity, VcpuLimitExceeded)
        "launch_message": (launched.get("message") or "")[:300],
    }


def _sum_nodepool(i):
    return {
        "name": i["metadata"]["name"],
        "weight": i["spec"].get("weight"),
        "gpu_limit": i["spec"].get("limits", {}).get("nvidia.com/gpu"),
        "gpu_in_use": i.get("status", {}).get("resources", {}).get("nvidia.com/gpu"),
        "consolidate_after": i["spec"].get("disruption", {}).get("consolidateAfter"),
    }


def _sum_node(i):
    conds = {c["type"]: c["status"] for c in i["status"].get("conditions", [])}
    labels = i["metadata"].get("labels", {})
    return {
        "name": i["metadata"]["name"],
        "instance_type": labels.get("node.kubernetes.io/instance-type"),
        "ready": conds.get("Ready"),
        "allocatable_gpu": i["status"].get("allocatable", {}).get("nvidia.com/gpu", "0"),
        "mig_config": labels.get("nvidia.com/mig.config"),
        "mig_state": labels.get("nvidia.com/mig.config.state"),
    }


def _sum_pod(i):
    return {
        "name": i["metadata"]["name"],
        "phase": i["status"].get("phase"),
        "node": i["spec"].get("nodeName"),
        "reason": next((c.get("message", "")[:200] for c in i["status"].get("conditions", [])
                        if c.get("type") == "PodScheduled" and c.get("status") == "False"), None),
    }


def _sum_event(i):
    return {
        "reason": i.get("reason"),
        "object": f'{i.get("involvedObject", {}).get("kind")}/{i.get("involvedObject", {}).get("name")}',
        "message": (i.get("message") or "")[:250],
        "count": i.get("count"),
        "last_seen": i.get("lastTimestamp"),
    }


SUMMARIZERS = {"nodeclaims": _sum_nodeclaim, "nodepools": _sum_nodepool,
               "nodes": _sum_node, "pods": _sum_pod, "events": _sum_event}


def handler(event, context=None):
    cluster = event["cluster"]
    resource = event["resource"]
    config.require_cluster(cluster)
    if resource not in RESOURCE_PATHS:
        raise config.ValidationError(f"resource '{resource}' not in {sorted(RESOURCE_PATHS)}")
    path = RESOURCE_PATHS[resource].format(ns=event.get("namespace", config.WORKER_NAMESPACE))
    items = k8s_client.get(cluster, path).get("items", [])
    return {"cluster": cluster, "resource": resource,
            "items": [SUMMARIZERS[resource](i) for i in items]}
