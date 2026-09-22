# =============================================================================
# karpenter.tf — Karpenter 컨트롤러 설치 (IAM/SQS 기반 + Helm 릴리스)
# =============================================================================
# Karpenter 동작 원리 요약:
#   1) 스케줄 불가(Pending) Pod 감지
#   2) Pod의 요구사항(리소스/셀렉터/톨러레이션)과 NodePool 제약을 조합해
#      최적 인스턴스를 계산 → EC2 Fleet API로 직접 생성 (ASG 미사용)
#   3) 노드가 비면 회수 (NodePool의 disruption 정책)
#
# 이 파일은 두 부분:
#   [A] module.karpenter — 컨트롤러가 EC2/IAM/SQS를 다룰 권한과 인프라
#   [B] helm_release     — 컨트롤러 자체를 클러스터에 설치
# =============================================================================

# [A] IAM roles, spot interruption SQS queue, EventBridge rules, Pod Identity
# 이 서브모듈이 만들어 주는 것:
#   - 컨트롤러 IAM 롤: EC2 RunInstances/Fleet, 서브넷/SG 조회 등 (Pod Identity로 연결)
#   - 노드 IAM 롤: GPU 노드 EC2 인스턴스가 쓸 롤 (ECR pull, CNI 등)
#   - SQS 큐 + EventBridge 규칙: Spot 중단 2분 경고를 큐로 수신 →
#     컨트롤러가 미리 drain (graceful 종료의 핵심)
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Controller policy (17 statements) exceeds the 6,144-char managed-policy
  # hard limit -> use an inline role policy (10,240-char limit) instead.
  # This is the module's documented fix for "LimitExceeded: PolicySize: 6144".
  # (managed policy 6,144자 제한은 Service Quotas로도 증설 불가한 하드 리밋)
  enable_inline_policy = true

  # Name must match the role referenced in the EC2NodeClass —
  # EC2NodeClass.spec.role이 이 이름을 문자열로 참조하므로
  # name_prefix(랜덤 접미사)를 끄고 고정 이름 사용
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${var.cluster_name}-karpenter-node"
  create_pod_identity_association = true # IRSA 대신 최신 방식인 Pod Identity 사용

  node_iam_role_additional_policies = {
    # SSM Session Manager로 GPU 노드에 셸 접속 가능하게 (nvidia-smi 디버깅용)
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

# [B] Karpenter 컨트롤러 Helm 설치
# Anonymous pull from public.ecr.aws (avoids local docker credential-helper
# dependency; fine for low-volume PoC pulls)
#
# values 설명 (heredoc 내부는 렌더링 diff 방지를 위해 여기서 주석):
#   nodeSelector karpenter.sh/controller: system 노드그룹에만 스케줄
#     (자신이 만든 GPU 노드에서 돌지 않도록 — 자기파괴 방지)
#   dnsPolicy Default: 노드의 DNS 사용 — CoreDNS 장애 시에도 컨트롤러 동작
#   settings.clusterName/clusterEndpoint: 노드 부트스트랩(조인) 대상 클러스터
#   settings.interruptionQueue: [A]에서 만든 SQS 큐 — Spot 중단 경고 수신
resource "helm_release" "karpenter" {
  namespace = "kube-system"
  name      = "karpenter"
  chart     = "oci://public.ecr.aws/karpenter/karpenter"
  version   = var.karpenter_chart_version
  wait      = true # CRD(NodePool/EC2NodeClass)가 설치 완료된 뒤에야
  # gpu-ladder 차트(CR 생성)가 실행되도록 완료를 대기

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  depends_on = [module.eks, module.karpenter]
}
