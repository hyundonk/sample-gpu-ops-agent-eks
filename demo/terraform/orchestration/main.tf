# =============================================================================
# demo/terraform/orchestration — Gate + SFN + 원복 Scheduler  [WP6]
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 6.0" }
    archive = { source = "hashicorp/archive" }
  }
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "${path.module}/../cluster/terraform.tfstate" }
}

data "terraform_remote_state" "agent" {
  backend = "local"
  config  = { path = "${path.module}/../agent/terraform.tfstate" }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "approver_email" {
  description = "리포트·승인 수신 이메일 (SNS 구독 — 확인 메일 승인 필요)"
  type        = string
  default     = ""
}

variable "shadow_mode" {
  description = "true = plan을 리포트만 (Execute 생략). write 활성화는 게임데이 때 false로"
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = { Project = "gpu-agent-demo", Environment = "demo", Purpose = "orchestration" }
}

data "aws_caller_identity" "me" {}

locals {
  name          = "gpu-agent-demo"
  # 순환 의존 차단: gate→SFN→Lambda→gate 순환을 이름 규칙 ARN으로 끊는다
  sfn_arn_built     = "arn:aws:states:${var.region}:${data.aws_caller_identity.me.account_id}:stateMachine:gpu-agent-demo-incident"
  execute_arn_built = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.me.account_id}:function:gpu-agent-demo-execute-action"
  cluster_name  = data.terraform_remote_state.cluster.outputs.cluster_name
  tool_arns     = data.terraform_remote_state.cluster.outputs.tool_function_arns
  incidents_url = data.terraform_remote_state.cluster.outputs.incidents_queue_url
  runtime_arn   = data.terraform_remote_state.agent.outputs.agent_runtime_arn
  tool_prefix   = "${local.cluster_name}-tool"
  write_tool_arns = [
    local.tool_arns["patch_nodepool_limits"],
    local.tool_arns["patch_consolidate_after"],
    local.tool_arns["patch_keda_max"],
    local.tool_arns["recover_gpu_stack"],
  ]
}

# ── 감사·쿨다운 테이블 ────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "incidents" {
  name         = "${local.name}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_key"
  attribute {
    name = "incident_key"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true # 감사 테이블 복구 가능성 (스캔 CKV_AWS_28)
  }
  tags = var.tags
}

# ── 리포트·승인 SNS ──────────────────────────────────────────────────────────
resource "aws_sns_topic" "reports" {
  name              = "${local.name}-reports"
  kms_master_key_id = "alias/aws/sns" # 저장 암호화 (AWS 관리 키 — 발행자 추가 권한 불필요)
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.approver_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.reports.arn
  protocol  = "email"
  endpoint  = var.approver_email
}

# ── Lambda 6종 (공용 zip) ────────────────────────────────────────────────────
data "archive_file" "orchestration" {
  type        = "zip"
  source_dir  = "${path.module}/../../orchestration"
  output_path = "${path.module}/orchestration.zip"
}

locals {
  lambdas = {
    gate = {
      env = {
        DDB_TABLE       = aws_dynamodb_table.incidents.name
        SFN_ARN         = local.sfn_arn_built
        SHADOW_MODE     = tostring(var.shadow_mode)
        CLUSTER_NAME    = local.cluster_name
        COOLDOWN_SEC    = "1800"
        VERIFY_WAIT_SEC = "600"
      }
    }
    invoke_agent   = { env = { AGENT_RUNTIME_ARN = local.runtime_arn } }
    execute_action = { env = { TOOL_PREFIX = local.tool_prefix } }
    verify         = { env = { CLUSTER_NAME = local.cluster_name } }
    approve_request = { env = { SNS_TOPIC_ARN = aws_sns_topic.reports.arn } }
    report = {
      env = {
        SNS_TOPIC_ARN      = aws_sns_topic.reports.arn
        DDB_TABLE          = aws_dynamodb_table.incidents.name
        EXECUTE_LAMBDA_ARN = local.execute_arn_built
        SCHEDULER_ROLE_ARN = aws_iam_role.revert_scheduler.arn
      }
    }
  }
}

resource "aws_iam_role" "orch" {
  for_each           = toset(["gate", "invoke_agent", "execute_action", "verify", "approve_request", "report"])
  name_prefix        = substr("${local.name}-${replace(each.key, "_", "-")}-", 0, 37)
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "orch_basic" {
  for_each   = aws_iam_role.orch
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "orch" {
  for_each         = local.lambdas
  function_name    = "${local.name}-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.orch[each.key].arn
  handler          = "${each.key}.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.orchestration.output_path
  source_code_hash = data.archive_file.orchestration.output_base64sha256
  environment {
    variables = each.value.env
  }
  tags = var.tags
}

# ── 개별 권한 ─────────────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "gate" {
  name = "gate"
  role = aws_iam_role.orch["gate"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
        Resource = replace(replace(local.incidents_url, "https://sqs.${var.region}.amazonaws.com/", "arn:aws:sqs:${var.region}:"), "/", ":") },
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.incidents.arn },
      { Effect = "Allow", Action = ["states:StartExecution"], Resource = aws_sfn_state_machine.incident.arn },
      { Effect = "Allow", Action = ["cloudwatch:GetMetricStatistics"], Resource = "*" },
    ]
  })
}

resource "aws_iam_role_policy" "invoke_agent" {
  name = "invoke-agent"
  role = aws_iam_role.orch["invoke_agent"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "bedrock-agentcore:InvokeAgentRuntime", Resource = "${local.runtime_arn}*" }]
  })
}

resource "aws_iam_role_policy" "execute_action" {
  name = "invoke-write-tools"
  role = aws_iam_role.orch["execute_action"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = local.write_tool_arns }]
  })
}

resource "aws_iam_role_policy" "verify" {
  name = "cloudwatch-read"
  role = aws_iam_role.orch["verify"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "cloudwatch:GetMetricStatistics", Resource = "*" }]
  })
}

resource "aws_iam_role_policy" "approve_request" {
  name = "sns-publish"
  role = aws_iam_role.orch["approve_request"].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.reports.arn }]
  })
}

resource "aws_iam_role_policy" "report" {
  name = "report"
  role = aws_iam_role.orch["report"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.reports.arn },
      { Effect = "Allow", Action = "dynamodb:UpdateItem", Resource = aws_dynamodb_table.incidents.arn },
      { Effect = "Allow", Action = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule"],
        # 원복 스케줄만 — 이름 접두로 범위 한정 (스캔 CKV_AWS_290/355)
        Resource = "arn:aws:scheduler:${var.region}:${data.aws_caller_identity.me.account_id}:schedule/default/revert-*" },
      { Effect = "Allow", Action = "iam:PassRole", Resource = aws_iam_role.revert_scheduler.arn },
    ]
  })
}

# ── 원복 Scheduler 롤 (execute_action 호출 전용) ─────────────────────────────
resource "aws_iam_role" "revert_scheduler" {
  name_prefix        = "${local.name}-revert-sched-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "revert_scheduler" {
  name = "invoke-execute"
  role = aws_iam_role.revert_scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.orch["execute_action"].arn }]
  })
}

# ── Gate ← incidents SQS ─────────────────────────────────────────────────────
resource "aws_lambda_event_source_mapping" "gate_sqs" {
  event_source_arn = replace(replace(local.incidents_url, "https://sqs.${var.region}.amazonaws.com/", "arn:aws:sqs:${var.region}:"), "/", ":")
  function_name    = aws_lambda_function.orch["gate"].arn
  batch_size       = 1
}

output "sfn_arn" {
  value = aws_sfn_state_machine.incident.arn
}

output "reports_topic_arn" {
  value = aws_sns_topic.reports.arn
}
