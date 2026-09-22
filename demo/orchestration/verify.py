"""verify Lambda — 조치 후 효과 측정 (§5.5 공통 실행 계약의 '10분 내 검증').

기준: 최근 5분 PendingWorkers 최솟값 0 (수요 해소) — 데모 단순화 기준.
재계획 루프(무효 시 Agent 재호출 ≤3회)는 차기 구현 — 현재는 결과를 리포트로 전달.
"""
import datetime
import os

import boto3

CLUSTER = os.environ.get("CLUSTER_NAME", "gpu-agent-demo-seoul")
_cw = boto3.client("cloudwatch")


def handler(event, context=None):
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(minutes=5)
    out = {}
    for name in ["PendingWorkers", "QueueDepth"]:
        r = _cw.get_metric_statistics(
            Namespace="GpuAgentDemo", MetricName=name,
            Dimensions=[{"Name": "Cluster", "Value": CLUSTER}],
            StartTime=start, EndTime=end, Period=60, Statistics=["Minimum"])
        pts = [p["Minimum"] for p in r["Datapoints"]]
        out[name] = min(pts) if pts else None
    resolved = (out.get("PendingWorkers") == 0)
    return {"resolved": resolved, "metrics": out}
