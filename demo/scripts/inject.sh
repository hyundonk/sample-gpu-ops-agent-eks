#!/usr/bin/env bash
# inject.sh — 데모 큐에 모사 작업 N건 주입 (클러스터 내부에서 redis-cli 실행)
# Valkey는 VPC 내부 전용이므로 로컬에서 직접 접근 불가 — 일회성 Pod로 주입한다.
#
# 사용: ./inject.sh [건수=30] [작업당 처리시간초=90]
# 전제: kubectl 컨텍스트가 데모 클러스터, demo/terraform/cluster가 apply된 상태
set -euo pipefail

COUNT="${1:-30}"
DURATION="${2:-90}"
TF_DIR="$(dirname "$0")/../terraform/cluster"
VALKEY_HOST="$(terraform -chdir="$TF_DIR" output -raw valkey_endpoint)"

echo "Injecting $COUNT jobs (duration=${DURATION}s each) into $VALKEY_HOST/gpu-jobs"

kubectl run queue-inject --rm -i --restart=Never --image=redis:7-alpine -- sh -c "
  for i in \$(seq 1 $COUNT); do
    redis-cli --tls -h $VALKEY_HOST -p 6379 LPUSH gpu-jobs \
      \"{\\\"id\\\":\\\"job-\$(date +%s)-\$i\\\",\\\"duration\\\":$DURATION}\" > /dev/null
  done
  echo \"queue depth: \$(redis-cli --tls -h $VALKEY_HOST -p 6379 LLEN gpu-jobs)\"
"
