# =============================================================================
# runtime.tf — AgentCore Runtime (Strands 파이프라인 컨테이너)
# =============================================================================
# 참조 프로젝트 교훈 반영:
#   - 실행 롤에 InvokeModel + InvokeGateway 누락 시 MCP 초기화 403 (CDK 주석 실증)
#   - Gateway URL은 Terraform 참조로 env 주입 (빈-env 장애 구조적 제거)
# v3 추가: SFN 콜백 권한 (SendTaskSuccess/Failure — task-token 비동기 계약)
# =============================================================================

resource "aws_ecr_repository" "agent" {
  name                 = "${local.name}/agent"
  image_tag_mutability = "MUTABLE" # 데모 반복 배포 편의 (CKV_AWS_51 수용 — 프로덕션은 IMMUTABLE 권장)
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete         = true
  tags                 = var.tags
}

resource "aws_iam_role" "runtime" {
  name_prefix        = "${local.name}-runtime-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id } }
    }]
  })
  tags = var.tags
}

data "aws_caller_identity" "me" {}

resource "aws_iam_role_policy" "runtime" {
  name = "runtime-permissions"
  role = aws_iam_role.runtime.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { # 모델 호출 (파이프라인 3단계) — 모델 계열로 범위 한정 (CKV_AWS_355)
        Sid      = "BedrockInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = ["arn:aws:bedrock:*::foundation-model/*", "arn:aws:bedrock:*:*:inference-profile/*"]
      },
      { # MCP read 도구 (없으면 403 — 참조 프로젝트 실증)
        Sid      = "InvokeGateway"
        Effect   = "Allow"
        Action   = "bedrock-agentcore:InvokeGateway"
        Resource = aws_bedrockagentcore_gateway.this.gateway_arn
      },
      { # task-token 비동기 계약 (경로 A)
        Sid      = "SfnCallback"
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure", "states:SendTaskHeartbeat"]
        Resource = "*"
      },
      { # ECR pull (컨테이너 기동)
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = aws_ecr_repository.agent.arn
      },
      { # 로그·트레이스 (Observability)
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "Xray"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = "gpu_agent_demo"
  description        = "GPU capacity/failure response agent (classify-investigate-plan)"
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agent.repository_url}:${var.agent_image_tag}"
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    # Gateway URL을 Terraform 참조로 주입 — 빈-env 장애 구조적 제거
    AGENTCORE_GATEWAY_ENDPOINT = aws_bedrockagentcore_gateway.this.gateway_url
    MODEL_ID                   = var.model_id
  }

  tags = var.tags
}

output "agent_runtime_arn" {
  description = "SFN Investigate(WP6)·운영자 직접 호출이 참조"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "gateway_url" {
  value = aws_bedrockagentcore_gateway.this.gateway_url
}

output "agent_ecr_url" {
  value = aws_ecr_repository.agent.repository_url
}
