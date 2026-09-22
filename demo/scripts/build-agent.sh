#!/usr/bin/env bash
# build-agent.sh — Agent 컨테이너 빌드·푸시 (finch, ARM64)
# 사용: ./build-agent.sh [tag=v1]   (ECR 리포는 agent 스택이 생성 — 먼저 apply 필요 시
#       리포만 타깃 생성: terraform -chdir=../terraform/agent apply -target=aws_ecr_repository.agent)
set -euo pipefail
TAG="${1:-v1}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
FINCH=/Applications/Finch/bin/finch
ECR=$("$FINCH" --version >/dev/null && terraform -chdir="$DIR/terraform/agent" output -raw agent_ecr_url 2>/dev/null || true)
if [ -z "$ECR" ]; then
  echo "ECR 리포가 없습니다. 먼저: terraform -chdir=$DIR/terraform/agent apply -target=aws_ecr_repository.agent"
  exit 1
fi
aws ecr get-login-password --region ap-northeast-2 | "$FINCH" login --username AWS --password-stdin "${ECR%%/*}"
"$FINCH" build --platform linux/arm64 -t "$ECR:$TAG" "$DIR/agent"
"$FINCH" push "$ECR:$TAG"
echo "pushed: $ECR:$TAG"
