# GPU Ops Agent on EKS

> An AI agent that classifies GPU capacity/failure incidents on Amazon EKS and plans safe, reversible responses — deterministic layers act in seconds, the agent judges in minutes, and Step Functions executes under triple guardrails.

EKS 기반 GPU 추론 플랫폼의 용량 확보 실패·장애에 자동 대응하는 AI Agent의 **설계와 실배포 검증 구현**입니다. Karpenter · KEDA · Amazon Bedrock AgentCore · Strands Agents · Step Functions로 구성됩니다.

## 핵심 설계 원칙

- **결정론은 Karpenter에게, 판단은 Agent에게** — 가용영역 재시도·Spot 사다리 폴백·온디맨드 최종 폴백·큐 기반 확장은 수 초 내 자동. Agent는 원인 분류(용량? 쿼터? GPU 스택?), 비용 회수, 추세 판단에만 개입
- **read/write 비대칭** — 읽기 도구 3종은 Agent가 직접(MCP Gateway), 쓰기 도구 4종은 Agent가 호출 불가(Gateway 미등록 — 호출 표면 자체가 없음). Agent의 산출물은 plan JSON까지, 실행은 Step Functions가 재검증 후 대행
- **3중 가드레일** — AgentCore Policy → Lambda 코드 재검증(LLM 출력 불신) → K8s RBAC(`resourceNames` 한정). 모든 조치는 가역적이며 원복(결정론 역산)이 짝으로 등록
- **Shadow 모드** — 판단은 전부 하되 실행은 리포트만. 판단 품질의 증거가 쌓인 순서로 write 권한을 단계적 활성화

## 검증 결과 (서울 리전 실배포)

| 항목 | 결과 |
| --- | --- |
| 알람 → AI 판단 → 리포트 | **19초 무인 완주** (task-token 비동기) |
| Spot 사다리 폴백 | 실전 ICE에서 **2초 내 자동 전환** (g7e → g6e) |
| 큐 워커 작업 보존 | 강제 축소 시 **손실 0** (drain 우선 + 재큐잉 폴백) |
| 오진 방지 | 쿼터 초과 상황에서 큐 적체에도 **불필요 조치 0건** — 에스컬레이션 선택 |
| 가드레일 | 경계 위반 테스트 16종 + 실기 거부(코드·RBAC 계층) 확인 |

발표자료: [`gpu-agent-demo-presentation.html`](gpu-agent-demo-presentation.html) (브라우저로 열기)

## 아키텍처

```
CloudWatch 알람 → EventBridge → SQS → Gate Lambda(중복 제거·쿨다운·컨텍스트)
  → Step Functions ─(task-token 비동기)→ AgentCore Runtime
                                          Strands 파이프라인: 분류 → 조사 → 계획
                                          (read 도구 3종은 조사 단계에만 — MCP Gateway)
  → Shadow 분기 / 승인(HIGH) → Execute(Map) → write 도구 4종 → EKS patch
  → Verify → Report(SNS·감사 기록·원복 타이머)
```

- 설계서: [`gpu-agent-unified-design.md`](gpu-agent-unified-design.md)
- 다이어그램: [`gpu-agent-architecture-v3.drawio`](gpu-agent-architecture-v3.drawio)

## 저장소 구조

```
demo/
├── terraform/
│   ├── cluster/         # EKS + Karpenter 사다리(NodePool 3종) + KEDA + Valkey 큐
│   │                    #   + 신호 계층(exporter·알람) + 도구 Lambda 7종 + RBAC
│   ├── agent/           # AgentCore Gateway(read 도구 target) + Runtime
│   └── orchestration/   # Gate + Step Functions + 원복 Scheduler + SNS
├── agent/               # Strands 판단 파이프라인 (분류→조사→계획) + 컨테이너
├── lambda-tools/        # 도구 7종 (read 3 + write 4) + 경계 위반 테스트
├── orchestration/       # Gate·invoke·execute·verify·report Lambda
├── worker/              # mock GPU 워커 (drain 우선 graceful shutdown)
└── scripts/             # 작업 주입·Agent 이미지 빌드
```

## 시작하기

### 사전 요구사항

- Terraform ≥ 1.5, AWS CLI, kubectl, Helm
- 컨테이너 빌드 도구 (finch 또는 docker)
- 대상 리전의 GPU 인스턴스(g7e/g6e) Spot vCPU 쿼터
- Bedrock Claude 모델 액세스 (기본: Sonnet 4.6 글로벌 프로파일)

### 배포 (3개 스택, 순서대로)

```bash
# 1. 클러스터 스택 — EKS·사다리·큐·신호·도구 (~20분)
cd demo/terraform/cluster
terraform init && terraform apply

# 워커 이미지 빌드·푸시 후 재적용
cd ../../worker
ECR=$(terraform -chdir=../terraform/cluster output -raw ecr_repository_url)
finch build --platform linux/amd64 -t $ECR:v1 . && finch push $ECR:v1

# 2. Agent 스택 — ECR 먼저, 이미지 빌드, 전체 적용
cd ../terraform/agent
terraform apply -target=aws_ecr_repository.agent
../../scripts/build-agent.sh v1
terraform apply

# 3. 오케스트레이션 스택 (Shadow 모드 기본)
cd ../orchestration
terraform apply -var approver_email=<수신 이메일>   # SNS 구독 확인 메일 승인 필요
```

### 동작 확인

```bash
# E2E: 알람 인위 전이 → 19초 뒤 SNS 리포트 + DynamoDB 감사 기록
aws cloudwatch set-alarm-state --alarm-name <클러스터명>-ladder-exhausted \
  --state-value ALARM --state-reason "wiring test" --region <리전>

# 부하 시험: 작업 30건 주입 → KEDA 확장 → 사다리 노드 조달 → 소진 → scale-to-zero
demo/scripts/inject.sh 30 90
```

> ⚠️ **비용**: 상시 약 $120/월(EKS 컨트롤 플레인·NAT·system 노드·Valkey) + GPU 노드는 시험 시간당 과금(g7e.2xl Spot 기준 ~$2.3/hr). NodePool `limits`가 비용 상한 역할을 합니다. 시험 후 큐를 비우면 워커·노드는 자동 회수됩니다.

## 운영 정책 결정 사항

- **가용성 우선**: 온디맨드 폴백 풀은 상시 개방(limits = 비용 캡)이며, Agent는 Spot 회복 시 온디맨드 잠식을 회수하는 사후 비용 최적화를 담당합니다. 비용 우선(잠금 + 사전 허가) 구성으로의 전환은 limits 값 하나입니다 — **SLO 대 비용 우선순위는 운영 주체의 사업 판단으로 확정하세요**
- 데모 간소화와 실환경 차이: 실제 용량 부족(ICE)은 재현 불가라 limits 소진으로 대체했고, 워커는 mock(sleep)입니다 — 분류기의 실전 입력 분포는 Shadow 운영에서 재검증이 필요합니다

## 로드맵

- Shadow 측정 + 게임데이 (write 단계적 활성화: 스택 복구 → 온디맨드 잠식 회수 → 리전 확장)
- 멀티리전 확장 (원격 리전 게이트 = KEDA pause 어노테이션, 계단식 병렬 개방)
- 수요 추세 프로파일 → posture slow loop (피크 전 선제 워밍·회수 타이밍)

## License

MIT No Attribution (MIT-0) — [`LICENSE`](LICENSE) 참조.

## 면책

본 저장소는 아키텍처 검증용 데모 구현입니다. 프로덕션 적용 전 보안 검토(네트워크 경계·IAM 최소권한·감사 요건)와 워크로드 특성에 맞는 상한·정책값 조정이 필요합니다.
