# =============================================================================
# karpenter-resources.tf — 사다리 NodePool 3종 + 공용 EC2NodeClass + MIG config
# =============================================================================
# PoC와 동일하게 로컬 Helm 차트로 배포 (plan 시점 클러스터 연결 불필요 →
# 클러스터 생성과 단일 apply 가능). 차이: 단일 풀 → 사다리 3풀(gpu-ladder 차트).
#
# 사다리 정의(ladder_pools 변수)는 Git 소유이며, gpu-od의 런타임 limits 개폐만
# Agent(write Lambda) 소유다 — 이 Terraform을 재적용하면 게이트가 Git 기본값
# (잠금)으로 되돌아가므로, 게임데이 중에는 apply를 피하거나 개방 상태를 확인할 것.
# =============================================================================

resource "helm_release" "gpu_ladder" {
  name             = "gpu-ladder"
  chart            = "${path.module}/charts/gpu-ladder"
  namespace        = "gpu-operator"
  create_namespace = true

  # 리스트 구조(pools)는 set 블록보다 values(yamlencode) 주입이 정확하다
  values = [
    yamlencode({
      clusterName     = var.cluster_name
      nodeIamRoleName = module.karpenter.node_iam_role_name
      ebsVolumeSize   = var.ebs_volume_size
      pools           = var.ladder_pools
    })
  ]

  # Karpenter CRDs (NodePool/EC2NodeClass)가 먼저 존재해야 함
  depends_on = [helm_release.karpenter]
}
