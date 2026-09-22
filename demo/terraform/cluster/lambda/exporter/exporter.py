"""큐 깊이 + 클러스터 신호 exporter — 알람 계층(WP3)의 메트릭 소스.

1분마다 (EventBridge Scheduler):
  GpuAgentDemo/QueueDepth            — Valkey list 길이 (큐 SLO 알람)
  GpuAgentDemo/CompletedJobs         — 처리 완료 누계
  GpuAgentDemo/PendingWorkers        — 스케줄 안 된 워커 Pod 수
                                        (5분 지속 시 "상시 사다리 소진" 알람 —
                                         Karpenter가 5분간 해소 못함 = 소진/실패)
  GpuAgentDemo/GpuNotAdvertisedNodes — Ready인데 GPU 미광고(allocatable 0) 노드 수
                                        (스택 복구 시나리오의 트리거)
"""
import os

import boto3
import redis

import k8s_client

VALKEY_HOST = os.environ["VALKEY_HOST"]
QUEUE = os.environ.get("QUEUE_NAME", "gpu-jobs")
RESULTS = os.environ.get("RESULTS_NAME", "gpu-results")
NAMESPACE = os.environ.get("METRIC_NAMESPACE", "GpuAgentDemo")
CLUSTER = os.environ.get("CLUSTER_NAME", "unknown")
WORKER_NS = os.environ.get("WORKER_NAMESPACE", "inference")

_r = redis.Redis(host=VALKEY_HOST, port=6379, ssl=True,
                 decode_responses=True, socket_timeout=5)
_cw = boto3.client("cloudwatch")


def _pending_workers() -> int:
    pods = k8s_client.get(
        f"/api/v1/namespaces/{WORKER_NS}/pods?fieldSelector=status.phase=Pending")
    return len(pods.get("items", []))


def _gpu_not_advertised() -> int:
    nodes = k8s_client.get("/api/v1/nodes?labelSelector=node-role=gpu")
    count = 0
    for n in nodes.get("items", []):
        conds = {c["type"]: c["status"] for c in n["status"].get("conditions", [])}
        ready = conds.get("Ready") == "True"
        gpu = int(n["status"].get("allocatable", {}).get("nvidia.com/gpu", "0"))
        if ready and gpu == 0:
            count += 1
    return count


def handler(event, context):
    metrics = {
        "QueueDepth": _r.llen(QUEUE),
        "CompletedJobs": _r.llen(RESULTS),
    }
    # K8s 조회 실패가 큐 메트릭까지 막지 않도록 분리
    try:
        metrics["PendingWorkers"] = _pending_workers()
        metrics["GpuNotAdvertisedNodes"] = _gpu_not_advertised()
    except Exception as e:  # noqa: BLE001 — 신호 결손은 알람 treat_missing으로 처리
        print(f"k8s signal collection failed: {e}")

    _cw.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {"MetricName": k, "Value": v, "Unit": "Count",
             "Dimensions": [{"Name": "Cluster", "Value": CLUSTER}]}
            for k, v in metrics.items()
        ],
    )
    return metrics
