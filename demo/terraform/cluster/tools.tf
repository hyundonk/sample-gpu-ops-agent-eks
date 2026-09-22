# =============================================================================
# tools.tf — 도구 Lambda 7종 (read 3 + write 4)  [WP4]
# =============================================================================
# 소스: demo/lambda-tools/ (의존성 없음 — boto3/stdlib만이라 pip 빌드 불필요)
# 권한 분리 (v3 §7.3의 비대칭을 IAM 수준에서 구현):
#   read 롤  → Access Entry 그룹 demo-signals-reader (WP3와 공유)
#   write 롤 → Access Entry 그룹 demo-tools-writer (rbac-tools.yaml, resourceNames 한정)
# 네트워크: K8s 접근 도구는 exporter SG 공유 (클러스터 SG 443 ingress 기허용 — WP3 실측)
# =============================================================================

locals {
  tools_src = "${path.module}/../../lambda-tools"

  # handler = 파일명.handler / role = read|write / vpc = EKS API 접근 필요 여부
  tools = {
    k8s_read                = { role = "read", vpc = true }
    cloudwatch_read         = { role = "read", vpc = false }
    spot_price_read         = { role = "read", vpc = false }
    patch_nodepool_limits   = { role = "write", vpc = true }
    patch_consolidate_after = { role = "write", vpc = true }
    patch_keda_max          = { role = "write", vpc = true }
    recover_gpu_stack       = { role = "write", vpc = true }
  }

  # 멀티클러스터 정의 — Phase 2: 도쿄/뭄바이 항목 추가만으로 확장 (코드 무변경)
  clusters_env = jsonencode({
    seoul = {
      name     = module.eks.cluster_name
      endpoint = module.eks.cluster_endpoint
      ca       = module.eks.cluster_certificate_authority_data
      region   = var.region
    }
  })
}

data "archive_file" "tools" {
  type        = "zip"
  source_dir  = local.tools_src
  output_path = "${path.module}/lambda/tools.zip"
  excludes    = ["tests", "tests/test_validators.py", "__pycache__"]
}

# ── IAM: read / write 롤 분리 ────────────────────────────────────────────────
resource "aws_iam_role" "tools" {
  for_each           = toset(["read", "write"])
  name_prefix        = "${var.cluster_name}-tools-${each.key}-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "tools_vpc" {
  for_each   = toset(["read", "write"])
  role       = aws_iam_role.tools[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "tools_read_extra" {
  name = "read-apis"
  role = aws_iam_role.tools["read"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricData"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:DescribeSpotPriceHistory"], Resource = "*" },
    ]
  })
}

# ── EKS Access Entry: 그룹 매핑 (RBAC은 gpu-ladder 차트가 관리) ───────────────
resource "aws_eks_access_entry" "tools_read" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.tools["read"].arn
  type              = "STANDARD"
  kubernetes_groups = ["demo-signals-reader"] # WP3 읽기 RBAC 재사용
  tags              = var.tags
}

resource "aws_eks_access_entry" "tools_write" {
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.tools["write"].arn
  type              = "STANDARD"
  kubernetes_groups = ["demo-tools-writer"] # resourceNames 한정 RBAC (3층)
  tags              = var.tags
}

# ── Lambda 7종 ───────────────────────────────────────────────────────────────
resource "aws_lambda_function" "tools" {
  for_each         = local.tools
  function_name    = "${var.cluster_name}-tool-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.tools[each.value.role].arn
  handler          = "${each.key}.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256

  dynamic "vpc_config" {
    for_each = each.value.vpc ? [1] : []
    content {
      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [aws_security_group.exporter.id] # 클러스터 SG 443 기허용
    }
  }

  environment {
    variables = {
      CLUSTERS     = local.clusters_env
      CLUSTER_NAME = var.cluster_name
    }
  }

  tags = var.tags
}

output "tool_function_arns" {
  description = "도구 Lambda ARN — WP5 Gateway target·WP6 SFN Execute가 참조"
  value       = { for k, f in aws_lambda_function.tools : k => f.arn }
}
