"""최소 EKS API 클라이언트 — Lambda에서 kubectl 없이 K8s API를 읽습니다.

토큰: aws eks get-token과 동일 방식 — STS GetCallerIdentity presigned URL을
"k8s-aws-v1." 접두사로 감싼 bearer token. EKS Access Entry(이 Lambda의 IAM 롤,
AmazonEKSViewPolicy)가 이 토큰의 신원을 클러스터 권한으로 매핑합니다.

WP4의 read 도구(k8s_read)가 이 모듈을 그대로 기반으로 사용합니다.
"""
import base64
import json
import os
import ssl
import tempfile
import urllib.request

import boto3
from botocore.signers import RequestSigner

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
CLUSTER_ENDPOINT = os.environ["CLUSTER_ENDPOINT"]          # https://xxx.eks.amazonaws.com
CLUSTER_CA_B64 = os.environ["CLUSTER_CA"]                  # base64 PEM
REGION = os.environ["AWS_REGION"]

_ca_path = None


def _ca_file() -> str:
    global _ca_path
    if _ca_path is None:
        f = tempfile.NamedTemporaryFile(mode="wb", suffix=".pem", delete=False)
        f.write(base64.b64decode(CLUSTER_CA_B64))
        f.close()
        _ca_path = f.name
    return _ca_path


def _token() -> str:
    """aws eks get-token 동등 구현 (presigned STS GetCallerIdentity)."""
    session = boto3.session.Session()
    sts_client = session.client("sts", region_name=REGION)
    service_id = sts_client.meta.service_model.service_id
    signer = RequestSigner(service_id, REGION, "sts", "v4",
                           session.get_credentials(), session.events)
    params = {
        "method": "GET",
        "url": f"https://sts.{REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": {},
        "headers": {"x-k8s-aws-id": CLUSTER_NAME},
        "context": {},
    }
    signed_url = signer.generate_presigned_url(
        params, region_name=REGION, expires_in=60, operation_name="")
    return "k8s-aws-v1." + base64.urlsafe_b64encode(
        signed_url.encode()).decode().rstrip("=")


def get(path: str) -> dict:
    """K8s API GET (예: /api/v1/nodes?labelSelector=node-role=gpu)."""
    url = CLUSTER_ENDPOINT + path
    if not url.startswith("https://"):  # file:// 등 비정상 스킴 차단
        raise ValueError("non-https endpoint rejected")
    ctx = ssl.create_default_context(cafile=_ca_file())
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {_token()}"})
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:  # nosec B310 nosemgrep — https 강제 검증 완료
        return json.loads(resp.read())
