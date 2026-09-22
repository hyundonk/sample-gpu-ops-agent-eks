"""mock GPU 추론 워커 — GPU 슬롯을 점유하고 큐 작업을 모사 처리합니다.

검증 목적 (demo-implementation-plan.md WP2):
  - KEDA(큐 깊이) → Pod 확장 → Karpenter 사다리 노드 조달의 E2E 재현
  - ★ graceful shutdown 시 처리 중 작업의 큐 반환(re-push) — 통합 설계서
    §2.3 전제 ③의 실증. Spot 중단·KEDA 축소(max→0 리전 게이트 원복)에서
    작업 손실이 없어야 한다.

동작 (데드라인 인지 drain — 2026-09-22 개선):
  BLPOP(gpu-jobs) → duration초 모사 처리 → 완료 시 gpu-results에 기록.
  SIGTERM 수신 시:
    ① 새 작업 수령은 즉시 중단
    ② 처리 중 작업은 "남은 작업 시간 ≤ 남은 grace 예산"이면 완주 후 종료 (drain)
       — mesh 생성류 20~30초 작업은 대부분 여기서 끝남: 낭비 연산 0, 중복 처리 0
    ③ 완주가 불가능할 때만 큐 반환 (re-push 폴백) — 안전망은 유지
  전제: terminationGracePeriodSeconds > DRAIN_BUDGET_SEC (차트에서 90s/60s)
"""
import json
import logging
import os
import signal
import socket
import time

import redis

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mock-worker")

VALKEY_HOST = os.environ["VALKEY_HOST"]
VALKEY_PORT = int(os.environ.get("VALKEY_PORT", "6379"))
QUEUE = os.environ.get("QUEUE_NAME", "gpu-jobs")
RESULTS = os.environ.get("RESULTS_NAME", "gpu-results")
DEFAULT_DURATION = int(os.environ.get("DEFAULT_DURATION_SEC", "90"))
# SIGTERM 후 처리 완주에 쓸 수 있는 예산 (grace period보다 작아야 — 반환·종료 마진)
DRAIN_BUDGET = int(os.environ.get("DRAIN_BUDGET_SEC", "60"))
WORKER_ID = socket.gethostname()

shutdown = False
term_at = None  # SIGTERM 수신 시각


def _on_term(signum, frame):
    global shutdown, term_at
    log.info("SIGTERM received — drain if finishable within budget, else re-push")
    shutdown = True
    term_at = time.time()


signal.signal(signal.SIGTERM, _on_term)
signal.signal(signal.SIGINT, _on_term)


def main() -> None:
    # ElastiCache Serverless는 전송 암호화(TLS)가 항상 활성
    r = redis.Redis(host=VALKEY_HOST, port=VALKEY_PORT, ssl=True,
                    decode_responses=True, socket_timeout=10)
    r.ping()
    log.info("worker=%s connected to %s:%s queue=%s", WORKER_ID, VALKEY_HOST, VALKEY_PORT, QUEUE)

    while not shutdown:
        item = r.blpop(QUEUE, timeout=5)  # 5초 타임아웃 — shutdown 플래그 주기 확인
        if item is None:
            continue
        raw = item[1]
        try:
            job = json.loads(raw)
        except json.JSONDecodeError:
            job = {"raw": raw}
        duration = int(job.get("duration", DEFAULT_DURATION))
        log.info("job=%s started (duration=%ss)", job.get("id", "?"), duration)

        completed = True
        for elapsed in range(duration):  # 1초 단위 tick — drain 판정 지점
            if shutdown:
                remaining_job = duration - elapsed
                remaining_budget = DRAIN_BUDGET - (time.time() - term_at)
                if remaining_job > remaining_budget:
                    # 예산 내 완주 불가 → 즉시 반환 (re-push 폴백)
                    completed = False
                    break
                # 완주 가능 → drain 계속 (낭비 연산 0)
            time.sleep(1)  # nosemgrep: arbitrary-sleep — mock 워커의 모사 처리 (의도됨)

        if completed:
            r.lpush(RESULTS, json.dumps({
                "id": job.get("id"), "worker": WORKER_ID, "finished_at": time.time()}))
            log.info("job=%s completed", job.get("id", "?"))
        else:
            # ★ 전제 ③: 미완료 작업 반환 — 작업 손실 0의 근거
            r.lpush(QUEUE, raw)
            log.info("job=%s RE-PUSHED to queue (graceful shutdown)", job.get("id", "?"))

    log.info("worker=%s exiting cleanly", WORKER_ID)


if __name__ == "__main__":
    main()
