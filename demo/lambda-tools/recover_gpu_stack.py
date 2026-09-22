"""write 도구 ④ recover_gpu_stack — GPU 스택 복구 (제어 항목 #4, MVP 1순위).

입력:
  relabel:    {"cluster","action":"relabel","node":"ip-..","mig_profile":"all-2g.48gb"}
  delete_pod: {"cluster","action":"delete_pod","namespace":"gpu-operator","pod":"..."}

경계: 프로파일 화이트리스트 + GPU 노드(node-role=gpu)만 + 지정 네임스페이스만.
플레이북 (PoC 실증, 부록 C 예제 D): 라벨 원복 → MIG 재분할 ~40초 → 오염 Pod 재생성.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "shared"))

import config
import k8s_client


def handler(event, context=None):
    cluster, action = event["cluster"], event["action"]
    config.require_cluster(cluster)
    config.validate_recover(action, event.get("mig_profile"), event.get("namespace"))

    if action == "relabel":
        node = event["node"]
        node_obj = k8s_client.get(cluster, f"/api/v1/nodes/{node}")
        if node_obj["metadata"].get("labels", {}).get("node-role") != "gpu":
            raise config.ValidationError(f"node '{node}' is not a GPU node (node-role!=gpu)")
        before = node_obj["metadata"]["labels"].get("nvidia.com/mig.config")
        k8s_client.merge_patch(cluster, f"/api/v1/nodes/{node}",
            {"metadata": {"labels": {"nvidia.com/mig.config": event["mig_profile"]}}})
        print(f"AUDIT recover_gpu_stack relabel cluster={cluster} node={node} "
              f"{before} -> {event['mig_profile']}")
        return {"ok": True, "tool": "recover_gpu_stack", "action": action,
                "node": node, "before": before, "after": event["mig_profile"]}

    # delete_pod — 재생성으로 슬라이스/디바이스 재할당
    ns, pod = event["namespace"], event["pod"]
    k8s_client.delete(cluster, f"/api/v1/namespaces/{ns}/pods/{pod}")
    print(f"AUDIT recover_gpu_stack delete_pod cluster={cluster} {ns}/{pod}")
    return {"ok": True, "tool": "recover_gpu_stack", "action": action,
            "namespace": ns, "pod": pod}
