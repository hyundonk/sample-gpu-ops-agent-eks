# =============================================================================
# eks.tf — EKS 컨트롤플레인 + system 노드그룹
# =============================================================================
# 노드 아키텍처가 2계층인 이유:
#   [1] system 노드그룹 (여기, Managed Node Group, 고정 2대):
#       Karpenter 컨트롤러와 GPU Operator의 컨트롤 Pod가 상주.
#       "Karpenter는 자신이 관리하지 않는 노드에서 돌아야 한다"는 원칙 —
#       Karpenter가 자기 노드를 회수해버리는 자기파괴를 막기 위함.
#   [2] GPU 노드 (karpenter-resources.tf의 NodePool, 동적 0~1대):
#       실제 추론 워크로드용. 수요(Pending Pod)가 있을 때만 생성.
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.eks_version

  # Terraform을 실행하는 IAM 주체에게 cluster-admin 권한 부여 —
  # 이게 있어야 같은 apply에서 helm provider가 클러스터에 배포 가능
  enable_cluster_creator_admin_permissions = true
  # kubectl을 로컬에서 쓰기 위한 퍼블릭 엔드포인트 (테스트 편의;
  # 프로덕션은 private + VPN/배스천 권장)
  endpoint_public_access = true

  # EKS 관리형 애드온. before_compute=true 는 "노드가 뜨기 전에 설치" —
  #   vpc-cni: 노드 기동 시 Pod 네트워킹이 즉시 동작해야 하므로 필수
  #   pod-identity-agent: Karpenter가 Pod Identity로 IAM 롤을 쓰기 위한 전제
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # System node group: Karpenter controller + GPU Operator control pods.
  # GPU capacity itself is provisioned by Karpenter (see karpenter-resources.tf).
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD" # GPU 없음 → 표준 AMI
      instance_types = ["m7i.large"]

      min_size     = 2 # 컨트롤러 HA를 위해 2대 유지
      max_size     = 3
      desired_size = 2

      labels = {
        # Karpenter Helm 차트의 nodeSelector가 이 라벨을 참조 —
        # "Karpenter는 자신이 만들지 않은 노드에서만 실행" 강제
        "karpenter.sh/controller" = "true"
        "node-role"               = "system"
      }
    }
  }

  # ★ Karpenter 보안그룹 자동탐색 태그 —
  # EC2NodeClass의 securityGroupSelectorTerms가 이 태그로 노드 SG를 찾는다.
  # 주의: 계정 내에서 이 태그를 가진 SG는 클러스터당 1개여야 함
  node_security_group_tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  tags = var.tags
}
