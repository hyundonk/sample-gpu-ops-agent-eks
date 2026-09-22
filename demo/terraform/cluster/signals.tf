# =============================================================================
# signals.tf — 알람 계층 (WP3): 사다리 소진·GPU 미광고 알람 + 인시던트 배선
# =============================================================================
# 신호 흐름 (통합 설계서 §7.1):
#   exporter Lambda(1분) → CloudWatch 메트릭 → 알람 (상태전이만)
#   → EventBridge 규칙 → SQS incidents 큐 (+DLQ) → [WP6] Gate Lambda
#
# exporter의 K8s 조회는 EKS Access Entry(View 정책)로 인가 — 이 패턴이
# WP4 read 도구(k8s_read)의 기반이 된다.
# =============================================================================

# ── exporter Lambda의 EKS 읽기 권한 (Access Entry + View 정책) ───────────────
resource "aws_eks_access_entry" "exporter" {
  cluster_name = module.eks.cluster_name
  principal_arn = aws_iam_role.exporter.arn
  type          = "STANDARD"
  # 관리형 AmazonEKSViewPolicy는 네임스페이스 리소스만 커버 (nodes 403 실측)
  # → 커스텀 RBAC 그룹 매핑 (gpu-ladder 차트의 rbac-signals.yaml)
  kubernetes_groups = ["demo-signals-reader"]
  tags              = var.tags
}

# exporter.tf의 Lambda에 클러스터 접속 정보 추가 주입이 필요하므로
# 환경 변수는 exporter.tf에서 통합 관리한다 (CLUSTER_ENDPOINT/CLUSTER_CA).

# ── 알람 ① 상시 사다리 소진 (5분 지속) ────────────────────────────────────────
# 의미론: 워커 Pod가 5분간 Pending = Karpenter가 사다리 전체로도 해소 못함
# (정상 조달은 1~2분 — WP1/2 실측). 게이트 개방 시나리오의 트리거.
resource "aws_cloudwatch_metric_alarm" "ladder_exhausted" {
  alarm_name          = "${var.cluster_name}-ladder-exhausted"
  alarm_description   = "워커 Pending 5분 지속 — 상시 사다리 소진 추정 (Agent 분류·게이트 개방 후보)"
  namespace           = "GpuAgentDemo"
  metric_name         = "PendingWorkers"
  dimensions          = { Cluster = var.cluster_name }
  statistic           = "Minimum" # 5분 내내 1 이상이어야 (일시 Pending 무시)
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ── 알람 ② GPU 미광고 (스택 복구 시나리오 트리거) ─────────────────────────────
# 노드 Ready인데 allocatable gpu=0 — MIG 적용 중(~40초 정상)과 구분하기 위해
# 5분 지속 조건 (정상 MIG 분할은 1분 내 완료 — 실측 40초).
resource "aws_cloudwatch_metric_alarm" "gpu_not_advertised" {
  alarm_name          = "${var.cluster_name}-gpu-not-advertised"
  alarm_description   = "Ready 노드의 GPU 미광고 5분 지속 — GPU 스택 장애 추정 (Agent 스택 복구 후보)"
  namespace           = "GpuAgentDemo"
  metric_name         = "GpuNotAdvertisedNodes"
  dimensions          = { Cluster = var.cluster_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  tags                = var.tags
}

# ── 인시던트 배선: 알람 상태전이 → EventBridge → SQS (+DLQ) ──────────────────
resource "aws_sqs_queue" "incidents_dlq" {
  name                    = "${var.cluster_name}-incidents-dlq"
  sqs_managed_sse_enabled = true
  tags = var.tags
}

resource "aws_sqs_queue" "incidents" {
  name                       = "${var.cluster_name}-incidents"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 120 # Gate Lambda 처리 시간 여유
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.incidents_dlq.arn
    maxReceiveCount     = 3
  })
  tags = var.tags
}

# 알람 "상태전이"만 매칭 — OK→ALARM 전이 시 1건 (raw 메트릭 폭풍 방지, §7.2)
resource "aws_cloudwatch_event_rule" "alarm_to_incident" {
  name        = "${var.cluster_name}-alarm-state-change"
  description = "데모 알람의 ALARM 전이 → 인시던트 큐"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = var.cluster_name }] # 이 데모의 알람만
      state     = { value = ["ALARM"] }
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "alarm_to_sqs" {
  rule = aws_cloudwatch_event_rule.alarm_to_incident.name
  arn  = aws_sqs_queue.incidents.arn
}

resource "aws_sqs_queue_policy" "incidents_from_eventbridge" {
  queue_url = aws_sqs_queue.incidents.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.incidents.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.alarm_to_incident.arn } }
    }]
  })
}

output "incidents_queue_url" {
  description = "인시던트 큐 (WP6 Gate Lambda의 이벤트 소스)"
  value       = aws_sqs_queue.incidents.url
}

# ── 클러스터 API 접근 허용 (프라이빗 엔드포인트 경로) ─────────────────────────
# VPC 내부에서는 EKS 엔드포인트가 프라이빗 ENI로 풀리므로, 클러스터 SG가
# Lambda SG의 443을 허용해야 한다 (실측: 미허용 시 urlopen timeout — 2026-09-22).
# WP4 도구 Lambda들도 같은 SG(exporter)를 공유하거나 동일 규칙을 추가한다.
resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_exporter" {
  security_group_id            = module.eks.cluster_security_group_id
  description                  = "exporter/tools Lambda to EKS API (private endpoint)"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.exporter.id
}
