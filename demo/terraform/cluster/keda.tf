# =============================================================================
# keda.tf — KEDA (큐 기반 오토스케일러) + mock 워커 워크로드
# =============================================================================
# KEDA redis 스케일러가 Valkey list 깊이를 보고 mock-worker replica를 조정.
# ScaledObject.maxReplicaCount = Agent 제어 항목 #3 (수요 완충 + 리전 게이트).
#
# 주의: 이 스택을 재적용하면 maxReplicaCount가 Git 기본값으로 되돌아간다 —
# 게이트 풀 limits와 동일한 구성/런타임 분리 원칙 적용 (게임데이 중 apply 금지).
# =============================================================================

variable "keda_chart_version" {
  description = "KEDA Helm chart version (2.20+ = k8s 1.33~1.35 지원)"
  type        = string
  default     = "2.20.0"
}

variable "worker_image_tag" {
  description = "mock 워커 이미지 태그. 배포 전 demo/worker에서 finch build/push 필요"
  type        = string
  default     = "v1"
}

variable "worker_max_replicas" {
  description = "KEDA maxReplicaCount — 서울 home 기본. 원격 리전은 0 (리전 게이트)"
  type        = number
  default     = 6
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = "keda"
  create_namespace = true

  depends_on = [module.eks]
}

resource "helm_release" "demo_workload" {
  name      = "demo-workload"
  chart     = "${path.module}/charts/demo-workload"
  namespace = "default" # 차트가 inference 네임스페이스를 자체 생성

  values = [
    yamlencode({
      namespace       = "inference"
      workerImage     = "${aws_ecr_repository.mock_worker.repository_url}:${var.worker_image_tag}"
      valkeyHost      = aws_elasticache_serverless_cache.queue.endpoint[0].address
      queueName       = "gpu-jobs"
      jobDurationSec  = "90"
      maxReplicaCount = var.worker_max_replicas
    })
  ]

  # KEDA CRD(ScaledObject) + Valkey 엔드포인트 선행 필요
  depends_on = [helm_release.keda, aws_elasticache_serverless_cache.queue]
}
