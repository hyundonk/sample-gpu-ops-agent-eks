# GPU 대응 Agent — AgentCore Runtime 컨테이너
# 플랫폼(ARM64)은 빌드 스크립트가 지정: build-agent.sh → finch build --platform linux/arm64
# HEALTHCHECK 미사용: AgentCore Runtime이 헬스를 외부에서 관리 (checkov CKV_DOCKER_2 수용)
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && useradd --create-home --uid 10001 agent
COPY entrypoint.py .
COPY gpu_agent/ gpu_agent/
USER agent
EXPOSE 8080
CMD ["python", "-u", "entrypoint.py"]
