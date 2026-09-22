"""AgentCore Gateway MCP 클라이언트 — 참조 프로젝트 검증 코드 (timeout 900s 교훈 포함)."""
import os

from mcp_proxy_for_aws.client import aws_iam_streamablehttp_client
from strands.tools.mcp import MCPClient


def create_mcp_client() -> MCPClient:
    endpoint = os.environ["AGENTCORE_GATEWAY_ENDPOINT"]
    region = os.environ.get("AWS_REGION", "ap-northeast-2")
    return MCPClient(
        lambda: aws_iam_streamablehttp_client(
            endpoint=endpoint,
            aws_region=region,
            aws_service="bedrock-agentcore",
            timeout=900,  # 기본 30s는 Lambda 실행을 못 덮음 (참조 프로젝트 실측)
        )
    )
