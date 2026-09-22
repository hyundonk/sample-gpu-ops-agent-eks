# =============================================================================
# versions.tf — Terraform/Provider 버전 고정 + Provider 인증 구성
# =============================================================================
# Terraform 프로젝트의 "입구" 역할을 하는 파일.
#   1) required_providers: 사용할 provider와 허용 버전 범위를 선언
#      (~> 6.0 은 "6.x 내에서 최신" — 7.0 같은 메이저 업그레이드는 차단)
#   2) provider 블록: 각 provider가 API를 호출할 때 쓸 인증/엔드포인트 설정
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # AWS 리소스(VPC/EKS/IAM/ECR 등) 생성용
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Helm 차트 배포용 (Karpenter, GPU Operator, 로컬 mig-infra 차트)
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# -----------------------------------------------------------------------------
# helm provider — "클러스터가 아직 없는데 어떻게 연결 설정을 하나?" 문제의 해법
#
# kubernetes/kubectl provider는 plan 시점에 클러스터 연결을 검증하기 때문에
# "클러스터 생성 + 그 위에 리소스 배포"를 한 번의 apply로 처리할 수 없다
# (닭-달걀 문제). 반면 helm provider는 연결을 apply 시점(실제 릴리스 설치
# 시점)까지 지연하므로 단일 apply가 가능하다.
#
# 인증 방식: 고정 토큰 대신 exec 플러그인으로 `aws eks get-token`을 매번
# 실행 → 토큰 만료 걱정 없이 항상 유효한 단기 자격증명 사용 (권장 패턴).
# module.eks.cluster_endpoint 참조 덕분에 Terraform이 "EKS 생성 후 helm 실행"
# 순서를 자동으로 보장한다 (암묵적 의존성).
# -----------------------------------------------------------------------------
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
