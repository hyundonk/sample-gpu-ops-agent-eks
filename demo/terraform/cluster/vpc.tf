# =============================================================================
# vpc.tf — 네트워크 계층 (VPC / 서브넷 / NAT)
# =============================================================================
# 구조: 2개 AZ에 걸쳐 public + private 서브넷 쌍.
#   - private 서브넷: EKS 노드(system + GPU) 배치. 외부 인바운드 차단
#   - public 서브넷 : NAT Gateway, (필요 시) ELB 배치
#   - 노드의 아웃바운드(이미지 pull, HF 모델 다운로드 등)는 NAT 경유
# =============================================================================

# 리전의 가용 AZ 목록을 동적으로 조회 (Local Zone은 제외)
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # 첫 2개 AZ만 사용 (테스트 규모 + NAT 비용 절약).
  # preflight에서 g7e.2xlarge 오퍼링이 1a/1b에 있음을 확인했고,
  # 이 slice가 정확히 그 두 AZ를 가리키는지 검증했다 (AZ ID 매핑 확인)
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # cidrsubnet(기준CIDR, 추가비트, 인덱스): /16을 쪼개 서브넷 CIDR 자동 계산
  #   private: /20 (4비트 추가) — 노드/Pod IP를 많이 쓰므로 크게
  #   public : /24 (8비트 추가, 48번째부터) — NAT/LB용이라 작게
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  # NAT 1개만 생성 (single_nat_gateway) — HA보다 비용 우선인 테스트 환경.
  # 프로덕션은 AZ당 1개(one_nat_gateway_per_az)로 AZ 장애 격리 권장
  enable_nat_gateway = true
  single_nat_gateway = true

  # kubernetes.io/role/* 태그: AWS Load Balancer Controller가
  # ELB를 배치할 서브넷을 찾을 때 사용하는 표준 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # ★ Karpenter 서브넷 자동탐색 태그 —
    # EC2NodeClass의 subnetSelectorTerms가 이 태그로 서브넷을 찾는다.
    # 즉 "Karpenter가 GPU 노드를 어느 서브넷에 띄울지"가 여기서 결정됨
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
