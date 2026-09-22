# =============================================================================
# demo/terraform/agent — AgentCore 계층 (Gateway + read 도구 3종 + Runtime)
# =============================================================================
# 클러스터 스택과 분리한 이유: Agent 반복 배포(이미지 갱신)가 클러스터 상태를
# 건드리지 않도록. 도구 Lambda ARN은 remote state로 참조.
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
    aws = {
      source = "hashicorp/aws"
      # bedrockagentcore 리소스 + gateway_target refresh panic(#48200) 수정 반영 최신
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "${path.module}/../cluster/terraform.tfstate"
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "agent_image_tag" {
  description = "Agent 컨테이너 태그 — demo/scripts/build-agent.sh로 빌드/푸시 후 apply"
  type        = string
  default     = "v1"
}

variable "model_id" {
  type    = string
  default = "global.anthropic.claude-sonnet-4-6"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "gpu-agent-demo"
    Environment = "demo"
    Purpose     = "agent-layer"
  }
}

locals {
  name      = "gpu-agent-demo"
  tool_arns = data.terraform_remote_state.cluster.outputs.tool_function_arns
}
