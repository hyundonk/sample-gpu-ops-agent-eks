# =============================================================================
# valkey.tf — 중앙 큐 (ElastiCache Serverless Valkey)
# =============================================================================
# 고객 환경의 "중앙 Valkey 큐"(통합 설계서 §2.3)를 최소 비용으로 재현.
#   - Serverless: 유휴 시 과금 최소, 캐시 데이터 상한으로 비용 캡
#   - 전송 암호화(TLS) 항상 활성 — 클라이언트(worker/KEDA/exporter)는 ssl=True
#   - Phase 2: 도쿄/뭄바이 VPC 피어링 후 이 SG에 원격 CIDR ingress 추가
# =============================================================================

resource "aws_security_group" "valkey" {
  name_prefix = "${var.cluster_name}-valkey-"
  description = "Valkey queue access (EKS nodes + exporter Lambda)"
  vpc_id      = module.vpc.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_nodes" {
  security_group_id            = aws_security_group.valkey.id
  description                  = "EKS nodes (worker, KEDA operator)"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_exporter" {
  security_group_id            = aws_security_group.valkey.id
  description                  = "queue depth exporter Lambda"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.exporter.id
}

resource "aws_elasticache_serverless_cache" "queue" {
  engine = "valkey"
  name   = "${var.cluster_name}-queue"

  # 비용 캡: 큐 페이로드는 작음 (작업 JSON 수백 바이트 × 수백 건)
  cache_usage_limits {
    data_storage {
      maximum = 1
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }

  security_group_ids = [aws_security_group.valkey.id]
  subnet_ids         = module.vpc.private_subnets

  tags = var.tags
}

output "valkey_endpoint" {
  description = "Valkey queue endpoint (TLS required)"
  value       = aws_elasticache_serverless_cache.queue.endpoint[0].address
}
