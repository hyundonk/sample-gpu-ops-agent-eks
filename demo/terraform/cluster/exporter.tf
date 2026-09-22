# =============================================================================
# exporter.tf — 큐 깊이 exporter Lambda + 1분 스케줄 + 큐 SLO 알람
# =============================================================================
# Valkey(list)는 네이티브 CloudWatch 메트릭이 없으므로, exporter가 큐 깊이를
# 커스텀 메트릭(GpuAgentDemo/QueueDepth)으로 게시한다 — 알람 계층(WP3)의 전제.
# redis 의존성은 apply 시점에 pip로 로컬 빌드(null_resource) 후 zip.
# =============================================================================

locals {
  exporter_src   = "${path.module}/lambda/exporter"
  exporter_build = "${path.module}/lambda/exporter/.build"
}

resource "null_resource" "exporter_deps" {
  triggers = {
    src = filemd5("${local.exporter_src}/exporter.py")
    k8s = filemd5("${local.exporter_src}/k8s_client.py")
  }
  provisioner "local-exec" {
    command = <<-EOT
      rm -rf ${local.exporter_build} && mkdir -p ${local.exporter_build}
      pip3 install redis==5.0.4 -t ${local.exporter_build} --quiet
      cp ${local.exporter_src}/exporter.py ${local.exporter_src}/k8s_client.py ${local.exporter_build}/
    EOT
  }
}

data "archive_file" "exporter" {
  type        = "zip"
  source_dir  = local.exporter_build
  output_path = "${path.module}/lambda/exporter.zip"
  depends_on  = [null_resource.exporter_deps]
}

resource "aws_security_group" "exporter" {
  name_prefix = "${var.cluster_name}-exporter-"
  description = "queue depth exporter Lambda"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_egress_rule" "exporter_all" {
  security_group_id = aws_security_group.exporter.id
  description       = "outbound to EKS API, Valkey, and AWS APIs via NAT"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "exporter" {
  name_prefix        = "${var.cluster_name}-exporter-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "exporter_vpc" {
  role       = aws_iam_role.exporter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "exporter_cw" {
  name = "put-metric-data"
  role = aws_iam_role.exporter.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "GpuAgentDemo" } }
    }]
  })
}

resource "aws_lambda_function" "exporter" {
  function_name    = "${var.cluster_name}-queue-exporter"
  role             = aws_iam_role.exporter.arn
  handler          = "exporter.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.exporter.output_path
  source_code_hash = data.archive_file.exporter.output_base64sha256

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.exporter.id]
  }

  environment {
    variables = {
      VALKEY_HOST      = aws_elasticache_serverless_cache.queue.endpoint[0].address
      QUEUE_NAME       = "gpu-jobs"
      METRIC_NAMESPACE = "GpuAgentDemo"
      CLUSTER_NAME     = var.cluster_name
      CLUSTER_ENDPOINT = module.eks.cluster_endpoint
      CLUSTER_CA       = module.eks.cluster_certificate_authority_data
    }
  }

  tags = var.tags
}

# ── 1분 주기 스케줄 (SPS Tracker와 동일 패턴) ────────────────────────────────
resource "aws_scheduler_schedule" "exporter" {
  name                = "${var.cluster_name}-queue-exporter"
  schedule_expression = "rate(1 minute)"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.exporter.arn
    role_arn = aws_iam_role.exporter_scheduler.arn
    retry_policy { maximum_retry_attempts = 0 } # 다음 분이 자연 재시도
  }
}

resource "aws_iam_role" "exporter_scheduler" {
  name_prefix        = "${var.cluster_name}-exp-sched-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "exporter_scheduler_invoke" {
  name = "invoke-exporter"
  role = aws_iam_role.exporter_scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.exporter.arn }]
  })
}

# ── 큐 SLO 알람 (WP3 선반영 — 인시던트 경로 트리거의 하나) ───────────────────
resource "aws_cloudwatch_metric_alarm" "queue_slo" {
  alarm_name          = "${var.cluster_name}-queue-backlog"
  alarm_description   = "큐 깊이 > 40이 10분 지속 — 수요가 공급을 초과 (Agent 트리거)"
  namespace           = "GpuAgentDemo"
  metric_name         = "QueueDepth"
  dimensions          = { Cluster = var.cluster_name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 10
  threshold           = 40
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}
