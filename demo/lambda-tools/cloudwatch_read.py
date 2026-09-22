"""read 도구 ② cloudwatch_read — 큐/신호 메트릭 + SPS Tracker 시계열.

입력: {"metrics": ["queue_depth"|"pending_workers"|"gpu_not_advertised"|"sps_g7e"...], "hours"?: 3}
출력: 메트릭별 최근 시계열 (최대 30점 — 토큰 절약).
"""
import datetime
import os

import boto3

CLUSTER = os.environ.get("CLUSTER_NAME", "gpu-agent-demo-seoul")
_cw = boto3.client("cloudwatch")

# 데모 메트릭 + SPS Tracker(기존 인프라 재사용) 정의
QUERIES = {
    "queue_depth": ("GpuAgentDemo", "QueueDepth", [{"Name": "Cluster", "Value": CLUSTER}]),
    "pending_workers": ("GpuAgentDemo", "PendingWorkers", [{"Name": "Cluster", "Value": CLUSTER}]),
    "gpu_not_advertised": ("GpuAgentDemo", "GpuNotAdvertisedNodes", [{"Name": "Cluster", "Value": CLUSTER}]),
    "completed_jobs": ("GpuAgentDemo", "CompletedJobs", [{"Name": "Cluster", "Value": CLUSTER}]),
    # SPS Tracker (sps-tracker/terraform — 서울 계정 동일 리전에 가동 중)
    "sps_g7e_seoul": ("SPS/Tracker", "SpotPlacementScore",
                      [{"Name": "ConfigId", "Value": "ladder-g7e-tc2-region-apne2"}]),
    "sps_g6e_seoul": ("SPS/Tracker", "SpotPlacementScore",
                      [{"Name": "ConfigId", "Value": "ladder-g6e-tc2-region-apne2"}]),
}


def handler(event, context=None):
    names = event.get("metrics", ["queue_depth", "pending_workers"])
    hours = min(int(event.get("hours", 3)), 48)
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(hours=hours)
    out = {}
    for n in names:
        if n not in QUERIES:
            out[n] = {"error": f"unknown metric (available: {sorted(QUERIES)})"}
            continue
        ns, metric, dims = QUERIES[n]
        period = max(60, int(hours * 3600 / 30))  # ≤30점
        resp = _cw.get_metric_statistics(
            Namespace=ns, MetricName=metric, Dimensions=dims,
            StartTime=start, EndTime=end, Period=period, Statistics=["Average"])
        pts = sorted(resp["Datapoints"], key=lambda d: d["Timestamp"])
        out[n] = [{"t": p["Timestamp"].strftime("%m-%dT%H:%M"), "v": round(p["Average"], 2)}
                  for p in pts]
    return {"hours": hours, "series": out}
