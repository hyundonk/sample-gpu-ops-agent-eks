# =============================================================================
# outputs.tf — apply 후 다른 도구/사람이 참조할 값들
# =============================================================================
# 확인: terraform output              (전체)
#       terraform output -raw ecr_repository_url  (스크립트에서 단일 값)
# =============================================================================

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

# finch build/push 대상 — 이미지 태그의 앞부분으로 사용
output "ecr_repository_url" {
  value = aws_ecr_repository.mock_worker.repository_url
}

# EC2NodeClass.spec.role과 일치해야 하는 노드 롤 이름 (디버깅 시 대조용)
output "karpenter_node_iam_role" {
  value = module.karpenter.node_iam_role_name
}

output "configure_kubectl" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
