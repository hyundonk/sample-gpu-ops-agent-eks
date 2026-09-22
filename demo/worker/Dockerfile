# mock 워커 — GPU 슬롯 점유 + 큐 소비 모사 (실제 CUDA 미사용)
# 빌드: finch build --platform linux/amd64 (GPU 노드는 x86_64)
# HEALTHCHECK 미사용: K8s liveness/readiness가 담당 (checkov CKV_DOCKER_2 수용)
FROM python:3.12-slim
RUN pip install --no-cache-dir redis==5.0.4 \
 && useradd --create-home --uid 10001 worker
COPY worker.py /app/worker.py
USER worker
# SIGTERM이 python 프로세스에 직접 전달되도록 exec form (drain-우선 종료의 전제)
ENTRYPOINT ["python", "-u", "/app/worker.py"]
