"""멀티클러스터 EKS API 클라이언트 — WP3 k8s_client의 확장판.

env CLUSTERS = {"seoul": {"name": ..., "endpoint": ..., "ca": <b64>}, ...}
Phase 2에서 tokyo/mumbai를 env 갱신만으로 추가한다 (코드 무변경).

read 도구는 demo-signals-reader, write 도구는 demo-tools-writer 그룹의
Access Entry로 인가된다 (호출 Lambda의 IAM 롤이 결정 — 같은 코드, 다른 권한).
"""
import base64
import json
import os
import ssl
import tempfile
import urllib.error
import urllib.request

import boto3
from botocore.signers import RequestSigner

CLUSTERS = json.loads(os.environ["CLUSTERS"])
REGION = os.environ["AWS_REGION"]

_ca_paths: dict = {}


def _ca_file(alias: str) -> str:
    if alias not in _ca_paths:
        f = tempfile.NamedTemporaryFile(mode="wb", suffix=f"-{alias}.pem", delete=False)
        f.write(base64.b64decode(CLUSTERS[alias]["ca"]))
        f.close()
        _ca_paths[alias] = f.name
    return _ca_paths[alias]


def _token(cluster_name: str, region: str) -> str:
    session = boto3.session.Session()
    sts = session.client("sts", region_name=region)
    signer = RequestSigner(sts.meta.service_model.service_id, region, "sts", "v4",
                           session.get_credentials(), session.events)
    params = {
        "method": "GET",
        "url": f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": {}, "headers": {"x-k8s-aws-id": cluster_name}, "context": {},
    }
    url = signer.generate_presigned_url(params, region_name=region,
                                        expires_in=60, operation_name="")
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def request(alias: str, method: str, path: str, body=None,
            content_type: str = "application/merge-patch+json") -> dict:
    cfg = CLUSTERS[alias]
    region = cfg.get("region", REGION)
    url = cfg["endpoint"] + path
    if not url.startswith("https://"):  # file:// 등 비정상 스킴 차단 (스캔 지적 반영)
        raise ValueError(f"non-https endpoint rejected: {url[:40]}")
    ctx = ssl.create_default_context(cafile=_ca_file(alias))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(  # nosemgrep: dynamic-urllib-use-detected — 위에서 https 강제
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {_token(cfg['name'], region)}",
                 **({"Content-Type": content_type} if data else {})})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:  # nosec B310 nosemgrep — https 강제 검증 완료
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        # RBAC 거부(403) 등을 구조화해 전파 — SFN/테스트가 사유를 판독 가능하게
        detail = e.read().decode()[:500]
        raise RuntimeError(f"k8s API {method} {path} -> HTTP {e.code}: {detail}") from e


def get(alias: str, path: str) -> dict:
    return request(alias, "GET", path)


def merge_patch(alias: str, path: str, body: dict) -> dict:
    return request(alias, "PATCH", path, body)


def delete(alias: str, path: str) -> dict:
    return request(alias, "DELETE", path)
