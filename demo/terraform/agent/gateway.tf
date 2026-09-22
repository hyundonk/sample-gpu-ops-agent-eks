# =============================================================================
# gateway.tf — MCP Gateway + read 도구 3종 target
# =============================================================================
# ★ v3 §7.3의 핵심 비대칭: write 도구 4종은 여기 등록하지 않는다 —
#   Agent가 호출할 표면 자체를 제거 (write는 SFN Execute가 직접 호출).
# 도구 description은 모델 행동 제어의 일부 (참조 프로젝트의
# description-driven tool use 패턴) — 호출 조건·제약을 명시한다.
# =============================================================================

resource "aws_iam_role" "gateway" {
  name_prefix        = "${local.name}-gateway-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "bedrock-agentcore.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "gateway_invoke_read_tools" {
  name = "invoke-read-tools"
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      # read 도구 3종만 — write ARN은 여기 없음 (게이트웨이 롤 수준에서도 차단)
      Resource = [
        local.tool_arns["k8s_read"],
        local.tool_arns["cloudwatch_read"],
        local.tool_arns["spot_price_read"],
      ]
    }]
  })
}

# IAM 전파 대기 — 롤 생성 직후 CreateGatewayTarget이 AssumeRole 검증에 실패
# ("Gateway service is not authorized to perform AssumeRole" — 실측 2026-09-22)
resource "time_sleep" "gateway_role_propagation" {
  create_duration = "15s"
  depends_on      = [aws_iam_role.gateway, aws_iam_role_policy.gateway_invoke_read_tools]
}

resource "aws_bedrockagentcore_gateway" "this" {
  depends_on = [time_sleep.gateway_role_propagation]

  name            = "${local.name}-gateway"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"

  protocol_configuration {
    mcp {
      search_type = "SEMANTIC"
    }
  }

  tags = var.tags
}

# ── read 도구 target 3종 ─────────────────────────────────────────────────────
resource "aws_bedrockagentcore_gateway_target" "k8s_read" {
  name               = "k8s-read"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Read Kubernetes state from a demo EKS cluster"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = local.tool_arns["k8s_read"]
        tool_schema {
          inline_payload {
            name        = "k8s_read"
            description = "EKS 클러스터 상태 읽기 (읽기 전용). nodeclaims의 launch_message에 용량/쿼터 에러 코드가 담기며 이것이 확보 실패 판별의 1차 근거다. nodepools로 사다리 소진(gpu_limit vs gpu_in_use), nodes로 GPU 광고 상태(mig_state, allocatable_gpu)를 확인한다. cluster는 'seoul'만 허용."
            input_schema {
              type        = "object"
              description = "k8s read query"
              property {
                name        = "cluster"
                type        = "string"
                description = "대상 클러스터 별칭 (허용: seoul)"
                required    = true
              }
              property {
                name        = "resource"
                type        = "string"
                description = "nodeclaims | nodepools | nodes | pods | events"
                required    = true
              }
              property {
                name        = "namespace"
                type        = "string"
                description = "pods 조회 시 네임스페이스 (기본 inference)"
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "cloudwatch_read" {
  name               = "cloudwatch-read"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Read demo metrics and SPS Tracker time series"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = local.tool_arns["cloudwatch_read"]
        tool_schema {
          inline_payload {
            name        = "cloudwatch_read"
            description = "메트릭 시계열 조회: queue_depth(큐 깊이), pending_workers, gpu_not_advertised, completed_jobs, sps_g7e_seoul/sps_g6e_seoul(Spot 확보 확률 점수, 낮을수록 공급 부족). 큐 수요의 실재 여부와 용량 추세 판단에 사용."
            input_schema {
              type        = "object"
              description = "metric query"
              property {
                name        = "metrics"
                type        = "array"
                description = "조회할 메트릭 이름 목록"
                required    = true
                items { type = "string" }
              }
              property {
                name        = "hours"
                type        = "integer"
                description = "조회 기간 (기본 3, 최대 48)"
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "spot_price_read" {
  name               = "spot-price-read"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "Read spot prices vs on-demand"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = local.tool_arns["spot_price_read"]
        tool_schema {
          inline_payload {
            name        = "spot_price_read"
            description = "GPU 인스턴스 Spot 시세와 온디맨드 대비 비율 조회. spot_od_ratio >= 1.0이면 가격 역전(온디맨드가 더 저렴 — 게이트 개방의 비용 근거). 게이트 개방 계획 전 비용 추정에 필수."
            input_schema {
              type        = "object"
              description = "price query"
              property {
                name        = "region"
                type        = "string"
                description = "리전 (기본 ap-northeast-2)"
              }
              property {
                name        = "instance_types"
                type        = "array"
                description = "인스턴스 타입 (기본 g7e.2xlarge, g6e.2xlarge)"
                items { type = "string" }
              }
            }
          }
        }
      }
    }
  }
}
