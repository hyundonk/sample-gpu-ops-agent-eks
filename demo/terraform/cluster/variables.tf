# =============================================================================
# variables.tf — GPU Agent demo 클러스터 (서울 home)
# =============================================================================
# PoC(../../terraform)에서 파생. 차이:
#   - 리전: ap-northeast-2 (서울) — Phase 2에서 이 변수로 도쿄/뭄바이 재적용
#   - NodePool: 단일 풀 → 사다리 3풀 (gpu-mig → gpu-g6e → gpu-od 게이트)
#   - limits 키: cpu → nvidia.com/gpu (통합 설계서 §2.1 — 물리 GPU 단위 예산)
# =============================================================================

variable "region" {
  description = "AWS region for this demo cluster"
  type        = string
  default     = "ap-northeast-2" # Phase 2: -var로 ap-northeast-1(도쿄)/ap-south-1(뭄바이) 재적용
}

variable "cluster_name" {
  description = "EKS cluster name (VPC 이름·karpenter.sh/discovery 태그 값으로도 재사용)"
  type        = string
  default     = "gpu-agent-demo-seoul"
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR block (Phase 2 피어링 대비 리전별로 겹치지 않게)"
  type        = string
  default     = "10.10.0.0/16" # 도쿄 10.11.0.0/16, 뭄바이 10.12.0.0/16 예약
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.14.0"
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v26.3.3"
}

variable "mig_config_profile" {
  description = "MIG parted config name (node label nvidia.com/mig.config). PoC 검증값."
  type        = string
  default     = "all-2g.48gb"
}

# ── 사다리 정의 (통합 설계서 §2.2의 데모 축소판) ─────────────────────────────
# 구조·weight·상한은 Git 소유(사람), gpu-od의 런타임 limits 개폐는 Agent 소유.
# gpuLimit은 "물리 GPU 수" 기준 예산 (g7e.2xl = GPU 1 = MIG 2슬롯).
variable "ladder_pools" {
  description = "Karpenter ladder NodePools (weight 내림차순 시도). gpuLimit '0' = 게이트 잠금."
  type = list(object({
    name          = string
    weight        = number
    capacityType  = string       # spot | on-demand
    instanceTypes = list(string)
    migProfile    = string       # ""이면 MIG 라벨 미부착 (풀 GPU)
    gpuLimit      = string       # nvidia.com/gpu 예산. "0" = 잠금 (게이트)
    gpuMax        = string       # Git 선언 상한 — write Lambda가 강제할 값 (문서화용 태그)
  }))
  default = [
    {
      # ① 상시·기본: g7e Spot + MIG 2g.48gb (슬롯 단가 최저 $1.13)
      name          = "gpu-mig"
      weight        = 100
      capacityType  = "spot"
      instanceTypes = ["g7e.2xlarge"]
      migProfile    = "all-2g.48gb"
      gpuLimit      = "2" # 데모 규모: 노드 2대 = 슬롯 4
      gpuMax        = "2"
    },
    {
      # ③ 상시·대체 타입: g6e Spot 풀 GPU (L40S 48GB — MIG 미지원, 노드당 1슬롯)
      name          = "gpu-g6e"
      weight        = 80
      capacityType  = "spot"
      instanceTypes = ["g6e.2xlarge"]
      migProfile    = ""
      gpuLimit      = "2"
      gpuMax        = "2"
    },
    {
      # ④ On-Demand 폴백 — 상시 개방 (가용성 우선 결정 2026-09-22).
      #    Spot ICE 시 Karpenter가 수 초 내 자동 폴백 (weight 최하위 = 최후 순위).
      #    limits가 비용 상한(캡) 역할. Agent의 역할은 개방 허가가 아니라
      #    "OD 잠식 회수"(Spot 회복 시 OD 워커 drain → Spot 재배치) + 예산 감시.
      name          = "gpu-od"
      weight        = 60
      capacityType  = "on-demand"
      instanceTypes = ["g7e.2xlarge", "g6e.2xlarge"]
      migProfile    = "all-2g.48gb"
      gpuLimit      = "2" # ★ 상시 개방 — 값이 곧 OD 비용 상한 (슬롯 2)
      gpuMax        = "2" # Agent가 조정해도 이 값을 넘을 수 없음 (Lambda 재검증)
    },
  ]
}

variable "ebs_volume_size" {
  description = "GPU 노드 루트 볼륨 (mock 워커는 작아도 되나 GPU Operator 이미지 감안)"
  type        = string
  default     = "100Gi"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    Project     = "gpu-agent-demo"
    Environment = "demo"
    Purpose     = "agent-scenario-validation"
  }
}
