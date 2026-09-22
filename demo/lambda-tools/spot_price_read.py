"""read 도구 ③ spot_price_read — 가격 역전 판정·비용 추정의 근거.

입력: {"region"?: "ap-northeast-2", "instance_types"?: [...]}
출력: 타입별 AZ 최신 Spot 시세 + 온디맨드 대비 비율 (≥1.0 = 가격 역전).
"""
import datetime

import boto3

# 온디맨드 상수 (2026-09 서울 실측 — sps-tracker collector와 동일 출처, USD/hr)
OD_PRICES = {
    "ap-northeast-2": {"g7e.2xlarge": 4.14, "g6e.2xlarge": 2.24},
    "ap-northeast-1": {"g7e.2xlarge": 4.88, "g6e.2xlarge": 2.53},
    "ap-south-1": {"g7e.2xlarge": 5.50, "g6e.2xlarge": 1.97},
}
DEFAULT_TYPES = ["g7e.2xlarge", "g6e.2xlarge"]


def handler(event, context=None):
    region = event.get("region", "ap-northeast-2")
    types = event.get("instance_types", DEFAULT_TYPES)
    ec2 = boto3.client("ec2", region_name=region)
    resp = ec2.describe_spot_price_history(
        InstanceTypes=types,
        ProductDescriptions=["Linux/UNIX"],
        StartTime=datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1),
    )
    latest = {}  # (type, az) → 최신 1건
    for p in sorted(resp["SpotPriceHistory"], key=lambda x: x["Timestamp"]):
        latest[(p["InstanceType"], p["AvailabilityZone"])] = float(p["SpotPrice"])

    out = []
    for (itype, az), spot in sorted(latest.items()):
        od = OD_PRICES.get(region, {}).get(itype)
        out.append({
            "instance_type": itype, "az": az, "spot_usd_hr": spot,
            "od_usd_hr": od,
            "spot_od_ratio": round(spot / od, 2) if od else None,  # ≥1.0 = 가격 역전
        })
    return {"region": region, "prices": out}
