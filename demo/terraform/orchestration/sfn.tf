# =============================================================================
# sfn.tf — 인시던트 상태 머신 (v3 §7.1: Investigate → Choice → Approve →
#          Execute(Parallel/Map) → Verify → Report)
# =============================================================================
# 재계획 루프(무효→Agent 재호출 ≤3회)는 데모 v1에서 단순화 — Verify 결과를
# Report에 전달하고 사람이 판단 (백로그: demo-implementation-plan.md WP6).
# =============================================================================

resource "aws_iam_role" "sfn" {
  name_prefix        = "${local.name}-sfn-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "sfn" {
  name = "invoke-lambdas"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "lambda:InvokeFunction",
        Resource = [for k in ["invoke_agent", "execute_action", "verify", "approve_request", "report"] : aws_lambda_function.orch[k].arn] },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" }, # X-Ray는 리소스 한정 불가
    ]
  })
}

resource "aws_sfn_state_machine" "incident" {
  name     = "${local.name}-incident"
  role_arn = aws_iam_role.sfn.arn
  # CKV_AWS_285(로그) 수용: SFN 실행 이력이 감사 용도를 담당 (데모 범위)
  tracing_configuration {
    enabled = true # X-Ray (CKV_AWS_284)
  }
  tags     = var.tags

  definition = jsonencode({
    Comment = "GPU incident response: Agent가 판단(plan), SFN이 실행 — v3 확정 아키텍처"
    StartAt = "InvokeAgent"
    States = {
      # ── 판단: task-token 비동기 — Agent가 SendTaskSuccess(plan)로 재개 ──
      InvokeAgent = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.orch["invoke_agent"].function_name
          Payload = {
            "task_token.$"     = "$$.Task.Token"
            "incident_id.$"    = "$.incident_id"
            "alarm.$"          = "$.alarm"
            "context_bundle.$" = "$.context_bundle"
          }
        }
        ResultPath     = "$.agent"
        TimeoutSeconds = 900
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Report" }]
        Next           = "ShadowCheck"
      }

      # ── Shadow 모드: 판단까지만 — Execute 생략, 리포트 직행 ──
      ShadowCheck = {
        Type    = "Choice"
        Choices = [{ Variable = "$.shadow_mode", BooleanEquals = true, Next = "Report" }]
        Default = "ActionCheck"
      }

      ActionCheck = {
        Type = "Choice"
        Choices = [
          # 조치 없음(에스컬레이션/조치 불필요) → 리포트만
          { Variable = "$.agent.plan.actions[0]", IsPresent = false, Next = "Report" },
          # HIGH → 사람 승인 (무과금 대기)
          { Variable = "$.agent.plan.risk", StringEquals = "HIGH", Next = "Approve" },
        ]
        Default = "Execute"
      }

      Approve = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.orch["approve_request"].function_name
          Payload = {
            "task_token.$"  = "$$.Task.Token"
            "incident_id.$" = "$.incident_id"
            "plan.$"        = "$.agent.plan"
          }
        }
        ResultPath     = "$.approval"
        TimeoutSeconds = 3600
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Report" }]
        Next           = "Execute"
      }

      # ── 실행: plan.actions[] 병렬 — Agent 미경유 (v3 §7.3 비대칭) ──
      Execute = {
        Type           = "Map"
        ItemsPath      = "$.agent.plan.actions"
        MaxConcurrency = 5
        ItemSelector   = { "action.$" = "$$.Map.Item.Value" }
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "ExecuteAction"
          States = {
            ExecuteAction = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.orch["execute_action"].function_name
                "Payload.$"  = "$"
              }
              OutputPath = "$.Payload"
              Retry      = [{ ErrorEquals = ["Lambda.ServiceException", "Lambda.TooManyRequestsException"], IntervalSeconds = 2, MaxAttempts = 2, BackoffRate = 2 }]
              End        = true
            }
          }
        }
        ResultPath = "$.exec_results"
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Report" }]
        Next       = "VerifyWait"
      }

      VerifyWait = {
        Type        = "Wait"
        SecondsPath = "$.verify_wait"
        Next        = "Verify"
      }

      Verify = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orch["verify"].function_name
          Payload      = {}
        }
        ResultSelector = { "result.$" = "$.Payload" }
        ResultPath     = "$.verify"
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Report" }]
        Next           = "Report"
      }

      # ── 종단: 리포트 + 감사 기록 + 원복 타이머 ──
      Report = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.orch["report"].function_name
          "Payload.$"  = "$"
        }
        End = true
      }
    }
  })
}
