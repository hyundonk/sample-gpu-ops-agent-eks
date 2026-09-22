# =============================================================================
# ecr.tf — 추론 서버 컨테이너 이미지 저장소
# =============================================================================
# 빌드/푸시 흐름 (로컬에서 finch 사용):
#   finch build --platform=amd64 -t <repo-url>:latest app/
#   aws ecr get-login-password | finch login ...
#   finch push <repo-url>:latest
# GPU 노드는 karpenter 노드 롤의 ECR read 권한으로 이 이미지를 pull한다.
# =============================================================================

resource "aws_ecr_repository" "mock_worker" {
  name = "gpu-agent-demo/mock-worker"
  # force_delete: 이미지가 남아 있어도 terraform destroy 허용 —
  # 테스트 환경 전용 설정. 프로덕션에서는 실수 방지를 위해 false 권장
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true # 푸시 시 취약점 스캔 자동 실행
  }

  tags = var.tags
}
