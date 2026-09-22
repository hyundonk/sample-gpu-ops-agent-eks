# GPU 용량·장애 자동 대응 Agent

**목적**: EKS GPU 추론 플랫폼에서 발생하는 용량 확보 실패와 워크로드 장애에 자동 대응하는 AI Agent의 설계문서입니다. 

**설계 원칙**: 결정론적으로 처리 가능한 대응은 Karpenter/KEDA/Lambda에 두고, **Agent는 판단이 필요한 지점에만** (Karpenter가 구분하지 못하는 실패 분류, 스케줄링 도메인 밖 액션, 상태 기반 판단(예산·쿨다운·추세·원복 타이밍) 개입합니다.

---

## 1. 개요 — Karpenter 동작 방식

본 문서의 모든 설계는, Karpenter가 추론 워커 Pod의 수요를 감지하여 GPU 노드를 생성하고 Pod가 그 위에서 실행되기까지의 아래 동작 방식을 전제로 설계되었습니다.

```
Pod 생성
  ↓
[1] kube-scheduler: 기존 노드에 자리가 있나? → 있으면 배치 (★weight 무관)
  ↓ (자리 없음 = Pending)
[2] Karpenter: 자격 필터(라벨·taint·limits) 통과한 풀 중 weight 최고부터 노드 생성 시도
  ↓ (ICE 시 풀 내 재시도 → 소진 시 다음 weight 풀 = 사다리 폴백)
[3] 노드 기동 → Ready (+ GPU 노드는 MIG 적용·device plugin이 allocatable 광고)
  ↓
[4] kube-scheduler: Pending Pod를 새 노드에 바인딩 — 배치의 주체는 다시 스케줄러
```

- **[1]** Pod가 생성되면 kube-scheduler가 먼저 기존 노드에서 자리를 찾습니다. 자리가 있으면 그대로 배치되며 Karpenter는 개입하지 않습니다. 이 단계에서 weight는 아무 역할을 하지 않습니다 — 이미 과금 중인 노드를 먼저 채우는 것이 의도된 정상 동작입니다.
- **[2]** 자리가 없어 Pending이 되면 Karpenter가 동작합니다. 클러스터의 모든 NodePool을 자동 인지하며(등록 절차 없음), 자격 필터(라벨·taint·limits — `limits: 0` 게이트 풀은 여기서 탈락) 통과 풀을 weight 내림차순으로 시도합니다. ICE 시 풀 내 재시도 후 다음 풀로 넘어가는 것이 **사다리 폴백**이며 수 초~수십 초에 자동 수행됩니다. **weight는 "Pod 배치 우선순위"가 아니라 "새 용량 조달 경로의 순서"입니다.** Pod는 요구만 선언하며 풀을 지정하는 필드 자체가 없습니다 — 워크로드와 용량 전략이 완전히 분리됩니다.
- **[3]** GPU 노드는 기동 후 MIG Manager가 GPU를 분할하고(실측 약 40초) device plugin이 슬라이스를 광고합니다. 이 시점의 실제 allocatable은 [2]의 Karpenter 예측과 다를 수 있습니다(MIG-blind: g7e를 GPU 1개로 계산하나 실제 광고는 2슬롯).
- **[4]** 바인딩은 다시 kube-scheduler의 역할입니다. Karpenter는 예측(Nominate)만 했을 뿐이며(Phase 1 실측: `Nominated` 이벤트), **예측과 실제가 어긋나면 실제 allocatable을 보는 스케줄러가 우선합니다.** 이 성질이 MIG-blind 우회(스케줄러가 2번째 Pod를 기존 노드에 바인딩), Pre-warm의 효과(Karpenter를 아예 거치지 않는 즉시 배치), 회수 방어(재배치 실패 위험 회피)를 성립시킵니다.

| 결정 | 주체 | 기준 |
| --- | --- | --- |
| 기존 노드에 들어갈까? ([1]) | kube-scheduler | 리소스 여유 + 라벨/taint (weight 무관) |
| 새 노드는 어느 풀로? ([2]) | Karpenter | weight 내림차순 (자격 필터 통과 풀 중) |
| 그 풀에서 어떤 인스턴스로? ([2]) | Karpenter | price-capacity-optimized (Spot) |
| 새 노드에 Pod 바인딩 ([4]) | kube-scheduler | **실제 allocatable** (예측 아님) |

---

## 2. 용어와 사다리 구성

### 2.1 용어 사전

| 용어 | 정의 |
| --- | --- |
| **사다리 (fallback ladder)** | 우선순위로 정렬해 둔 NodePool의 열입니다. 높은 우선순위 풀부터 시도하고 ICE 시 자동으로 다음 풀로 내려갑니다 |
| **상시 사다리** | 항상 열려 있는 저비용 계층입니다 (기본 대비 슬롯 단가 +35% 이내 — 정책값, Git 선언). Karpenter가 Agent 개입 없이 자동 전환하는 범위입니다 |
| **게이트 풀 (gate pool)** | 고비용 계층(OD, p4de 대량 등)을 `limits: 0`으로 잠가 둔 NodePool입니다. 정의는 Git에, 개폐는 Agent에 있습니다 — "비용이 드는 문은 판단을 거쳐야 열린다"는 설계입니다 |
| **`limits`** | NodePool의 자원 총량 상한입니다. 본 설계는 GPU 풀의 예산 키로 `nvidia.com/gpu`를 사용합니다: `"0"`=잠금. **집계 기준은 노드가 광고하는 GPU 리소스 총량입니다** — MIG 노드는 슬롯 수로 집계되므로(데모 실측 2026-09-21: g7e MIG 노드 1대가 예산 2를 소비) `"4"` = g7e MIG 노드 2대(슬롯 4) 또는 g6e 4대. 개폐 스위치이자 예산 상한이며 기존 노드에는 영향이 없습니다 |
| **`weight`** | NodePool 간 우선순위(0~100)입니다. 사다리의 순서를 만드는 필드로, 구조적 성격이므로 사람(Git)이 소유합니다 |
| **`consolidateAfter`** | 노드가 빈 뒤 회수까지 대기하는 시간입니다 (평시 30m). 용량 부족 시기에 늘리면 성급한 반납→재확보 실패 위험을 피할 수 있습니다 |
| **원복 안정 조건** | 진입과 복귀의 기준을 다르게 두는 설정입니다 (예: 점수 ≤3이면 개방하되, 원복은 ≥6이 24시간 유지되어야). 기준이 하나면 경계값 근처에서 열림/닫힘이 반복(플래핑)되므로, 복귀 기준을 더 엄격하게 잡아 이를 차단합니다. 최소 체류 시간·변경폭 상한과 함께 posture 안정성 3종 세트입니다 |
| **posture (자세)** | 특정 시점의 런타임 배치 태세입니다 — 어떤 게이트가 열려 있고 어느 리전에 무게가 실려 있는가. 구성(config)이 "의도"라면 posture는 "현재 상태"입니다 |
| **ODCR** *(차기 단계 보류)* | 용량을 확정 예약하는 EC2 기능입니다. 미사용에도 과금되는 비용 약정이므로 이번 단계에서 제외합니다 (§5 보류 항목) |

### 2.2 서울 리전 사다리 구성 예

| 순서 | NodePool | weight | limits (평시) | 내용 | 계층 |
| --- | --- | --- | --- | --- | --- |
| 1 | `gpu-mig` | 100 | gpu: 8 | g7e.2xl~8xl **Spot** + MIG 2g.48gb ($1.68/슬롯) | 상시 |
| 2 | `gpu-mig-large` | 90 | gpu: 8 | g7e 상위 사이즈 Spot, 동일 MIG | 상시 |
| 3 | `gpu-g6e` | 80 | gpu: 8 | g6e **Spot**, 풀 GPU ($2.24/슬롯) | 상시 |
| 4 | `gpu-od` | 60 | **gpu: 4 (상시 개방 = 비용 캡)** | g7e/g6e **On-Demand** | **폴백 (상시)** |
| 5 | `gpu-p4de` | 40 | **gpu: 0 (잠김)** | p4de MIG 3g.40gb 대량 | **게이트** |

> **⚖️ 설계 변경 (2026-09-22) — 가용성 우선**: 데모 검증 과정에서 "준 실시간성 > 비용" 우선순위 판단에 따라 **OD 풀(④)을 상시 개방**으로 전환했습니다. Spot 부족 시 Karpenter가 수 초 내 자동 폴백하며, limits가 비용 상한(캡) 역할을 합니다. Agent의 비용 역할은 사전 허가에서 **사후 회수**로 바뀝니다 — "OD 잠식 회수"(Spot 회복 증거 확보 시 OD 워커를 계획 재생성해 Spot 재배치 유도, 빈 OD 노드 자연 회수) + OD 점유율·실효 비용 감시. p4de 대량(⑤) 등 대형 약정성 계층과 **리전 확장 게이트는 잠금 유지** (여전히 판단 사안). ⚠️ 이 우선순위(SLO 대 비용)는 **고객 사업 판단으로 최종 확정 필요** — 게이트(잠금) 구성으로의 전환은 limits 값 하나입니다.

평시에는 ①~④를 Karpenter가 자동 순회합니다 (Spot 우선은 weight 순서가 보장 — OD는 최후 순위). NodePool YAML 원형과 상세 트레이스는 부록 A/B를 참조합니다.

### 2.3 배포 토폴로지 — 중앙 큐 + 3리전 GPU 클러스터

```
[서비스 플랫폼 클러스터 (별도)] → 요청 적재 → [ElastiCache Valkey 중앙 큐]
                                                    ↑ (크로스 리전 접근: TGW/피어링)
        ┌───────────────────────┬───────────────────────┐
   [서울 EKS]               [도쿄 EKS]              [뭄바이 EKS]
   KEDA 평시 가동            KEDA 일시정지(0) †        KEDA 일시정지(0) †
                            († paused-replicas 어노테이션 — 리전 게이트)
   + Karpenter 사다리        + Karpenter 사다리        + Karpenter 사다리
   (§2.2 전체)              (리전별 구성)             (리전별 구성)
```

- **세 리전의 KEDA가 같은 중앙 큐를 소비원으로 봅니다** — 작업 라우팅 계층이 불필요하며, "어느 리전이 일하는가"는 각 리전 KEDA의 게이트 상태가 결정합니다. 원격 리전은 평시 `autoscaling.keda.sh/paused-replicas: "0"` 어노테이션으로 정지(게이트 닫힘 — **KEDA CRD가 `maxReplicaCount ≥ 1`을 강제하므로 max=0이 아니라 pause 어노테이션이 공식 메커니즘**, 데모 실측 2026-09-22)되어 수요가 발생하지 않고, 따라서 Karpenter도 노드를 만들지 않습니다 (리전 유지비 = system 노드만)
- Valkey는 list 소비 특성상 여러 리전의 워커가 동시에 pop해도 각 작업은 정확히 한 워커에 배정됩니다
- **전제 인프라**: ① 도쿄/뭄바이 VPC ↔ 중앙 큐 VPC 네트워크 연결(TGW/피어링) ② 모델 weight S3 CRR + ECR 복제 ③ 워커 종료 시 작업 보존 패턴(Valkey에는 visibility timeout이 없음): **drain 우선** — 단위 작업이 짧으므로(mesh 생성 20~30초) SIGTERM 수신 시 남은 작업이 grace 예산 내면 완주 후 종료(낭비 연산·중복 처리 0), 완주 불가 시에만 큐 반환(re-push 폴백). Spot 중단 2분 경고·게이트 원복 모두 이 경로를 탄다 (grace period > 작업 최대 시간 + 마진으로 설정) ④ 클러스터별 도구 Lambda Access Entry/RBAC

---

## 3. 문제 유형 분류 —

Agent의 첫 임무는 분류입니다. 같은 증상(Pod Pending)이라도 원인별로 유효한 대응이 다르며, **오진(예: 쿼터 문제를 용량 부족으로)이 가장 큰 낭비**를 만듭니다. 단일 Agent가 세 갈래 — **확보 실패**(GPU를 구하지 못함) · **워커 이상**(확보한 GPU 위의 장애) · **용량 추세**(미리 읽는 흐름) — 를 모두 판별합니다.

### 3.1 확보 실패 — GPU를 구하지 못하는 문제 (용량)

| 유형 | 겉으로 보이는 현상 | 판별 방법 |
| --- | --- | --- |
| **특정 가용영역 부족** | NodeClaim `Launched=False`, `InsufficientInstanceCapacity` | **NodeClaim 이벤트의 에러 코드·가용영역** 확인, 다른 가용영역 SPS 정상 |
| **리전 전체 부족** | 모든 가용영역에서 위 실패가 반복 | SPS 전 가용영역 저점 + Spot 시세 ≥ 온디맨드 (확증) |
| **Spot 중단 급증** | Spot만 실패하고 중단 경고가 빈발 | 중단 경고 큐 유입률 |
| **쿼터 초과** | `VcpuLimitExceeded` 계열 에러 | **NodeClaim 이벤트의 에러 코드** — 용량 문제와 명확히 구분 |
| **GPU 미광고** | 노드는 Ready인데 `nvidia.com/gpu: 0` | MIG Manager/device plugin 로그, `mig.config.state=failed` |
| **장기 부족** | 리전 전체 부족이 수 시간 이상 지속 | SPS 히스토리 추세 |
| **가격 역전** | 할당은 되지만 Spot 시세 ≥ 온디맨드 | 시세 vs 온디맨드 비교 |

### 3.2 워커 이상 — 확보한 GPU 위에서 생기는 문제 (장애 — 고객 시나리오 #2)

| 유형 | 겉으로 보이는 현상 | 대응 |
| --- | --- | --- |
| **메모리 누수** | **슬롯별 DCGM 메모리 추세** 우상향, OOM 근접 | 누수 Pod 특정 → 드레인 후 계획 재시작 + 재발 주기 Memory 기록 |
| **성능 저하** | 슬롯별 latency p90 드리프트 | 최근 배포/설정 변경 상관분석 → 롤백 권고 또는 재시작 |
| **재부팅 후 검증** | patch 재부팅 이벤트 + MIG 재적용 관찰 | 재부팅 후 스택 정상화 검증 (스택 복구 절차 재사용) |



### 3.3 용량 추세 — 미리 대비하기 위한 흐름 읽기 (SPS Tracker 입력)

점수 하나가 아니라 **패턴**을 봅니다. 전부 posture 결정용이며 실행은 결정론 계층이 수행합니다.

| 패턴 | 예 | 해석 | 대비 액션 |
| --- | --- | --- | --- |
| **지속 저점** | 기본 리전 점수 ≤3이 6시간+ | 공급 부족 지속 | 폴백 풀 사전 준비 · 게이트 개방 준비도 상향 · 노드 보유 시간 연장 |
| **급락** | 24시간 변화량 ≤ -3 | 용량 급축소의 전조 | 사다리 하위 계층 선제 개방 준비 (확정 검증 수단인 ODCR 프로브는 차기 단계) |
| **구조적 하강** | 7일에 걸친 완만한 하락 | 수급 구조 변화 | 리전 weight 재조정 **제안** (사람 승인) |
| **피크 격차 확대** | 평시(2대 기준)–피크(10대 기준) 점수 격차 확대 | 풀이 얕아짐 — 버스트 흡수력 저하 | 피크 이벤트 전 대비 규모 상향 |
| **리전 순위 역전** | 리전 간 점수 순위 역전이 N일 지속 | 사다리 순서와 실수급 불일치 | 사다리 재정렬 제안 리포트 (근거 그래프, 사람이 IaC로 반영) |
| **회복** | 저점 후 상승 반전 | 원복 타이밍 | 개방했던 계층 원복 — **원복 안정 조건** 적용 |

### 3.4 수요 추세 — 시간대 프로파일 (추가 2026-09-22)

§3.3이 공급(Spot 확보 확률)의 흐름이라면, 이 절은 **수요(추론 요청 유입)의 흐름**입니다. 둘이 합쳐져야 posture 판단이 완성됩니다 — "공급이 마르는 시각"과 "수요가 몰리는 시각"이 겹칠 때가 진짜 위험입니다.

- **데이터**: 유입률 = ΔCompletedJobs + ΔQueueDepth (exporter 1분 시계열 → S3 장기 보존). 프로파일 = 요일×시간대별 유입률 중앙값/p90 (최근 4주, 일 1회 배치 계산 — **계산은 결정론**)
- **운영 반영 (posture 모드의 판단 입력 — 기존 제어 항목 재사용)**:

| 반영 지점 | 제어 항목 | 판단 예 |
| --- | --- | --- |
| 피크 전 선제 워밍 | #2 노드 보유 연장 | 평일 19시 피크 프로파일 → 18시대에 consolidateAfter 연장 (콜드스타트를 수요 도착 전에 흡수) |
| 시간대별 수요 완충 | #3 KEDA max | 심야 저수요 시간대 하향 / 피크 전 원복 |
| OD 잠식 회수 타이밍 | (회수 판단) | "다음 피크까지 여유가 있는가" — 피크 직전 회수(재확보 위험) 회피 |
| 리전 확장 준비도 | 리포트 | 주간 최대 피크 전 원격 리전 사전 조건 점검 |

- **예측 수준**: 시간대 프로파일(naive seasonal)로 시작합니다 — 필요한 예측 지평이 콜드스타트 리드타임(~5-7분)+MIG 재분할(40초) 수준이므로 프로파일만으로 가치 대부분을 확보합니다. ML 예측(Prophet 등)은 실데이터 축적 후 한계효용을 보고 판단합니다
- **전제**: 고객 실운영 로그로 프로파일 캘리브레이션 (데모의 모의 패턴은 검증용)

**교차 확증 규칙**: 추세 단독으로 액션하지 않습니다 — SPS 하락 + Spot/온디맨드 가격 비율 상승이 동시일 때만 격상하고, 두 지표가 어긋나면 관망합니다. 자체 할당 성공률 이력(캘리브레이션, §8 P3)이 쌓이면 임계값을 데이터로 튜닝합니다.

---

## 4. 대응 시나리오 — 이번 단계 (제어 항목 4종으로 실행 가능한 범위)

### 4.0 전제 계층: Karpenter가 자동 처리하는 부분 (Agent 무관)

가용영역 재시도와 상시 사다리 폴백은 §2.2의 NodePool 선언만으로 Karpenter가 수 초~수십 초에 자동 수행합니다. Agent는 이 계층이 **소진된 뒤에만** 개입하며, 평시에는 폴백 발생 사실과 비용 변화를 기록·리포트하는 관찰자입니다.

### 4.1 이번 단계 시나리오 6종

| 시나리오 | 발동 조건 | 사용 제어 항목 | 위험도 |
| --- | --- | --- | --- |
| **게이트 개방 + 비용 관리** | 리전 전체 부족 · Spot 중단 급증 · 가격 역전 | #1 (게이트 limits) | 중간 — 예산·원복 타이머 동반 |
| **노드 보유 연장** | SPS 지속 저점 | #2 (consolidateAfter) | 낮음 (회수 지연 방향 — fail-safe) |
| **큐 완충** | 전체 병행 | #3 (KEDA maxReplica) | 낮음 — 인프라 무접촉 |
| **스택 복구** | **GPU 미광고 · 재부팅 후 검증** | #4 (라벨 원복·Pod 재생성) | 낮음 — **MVP 1순위** |
| **리전 확장 (계단식 병렬 개방)** | 리전 부족 계열 (단계별) | #1 + **#3의 멀티클러스터 확장** ({현재 리전 OD ∥ 다음 리전 Spot} 동시) | 중간 — 단계당 예산·원복 동반 |
| **구조화 에스컬레이션** | 전체 (최후) | 없음 (리포트+승인 대기) | — |

**게이트 개방 + 비용 관리** — 상시 사다리 전체 소진(리전 전체 부족 확증) 시 게이트 풀(`gpu-od` 등)의 limits를 개방합니다. Agent의 본질적 기여는 개방 자체가 아니라 **비용 정책**입니다: 체류 시간 상한(예: 6h 재평가), 인시던트당 비용 상한(예: +$50/hr), 누적 비용의 Memory 기록, 회복 시 원복. 가격 역전(Spot ≥ 온디맨드) 감지 시에는 OD가 오히려 저렴하므로 즉시 개방을 권고합니다.

**노드 보유 연장** — SPS 지속 저점 등 용량 부족 시기에 `consolidateAfter`를 연장(30m→4h)하여 "확보한 노드를 성급히 반납했다가 재확보에 실패하는" 위험을 방어합니다. 회복 판정은 원복 안정 조건을 따릅니다.

**큐 완충** — 확보 불가능한 replica를 계속 요구하며 Pending을 쌓지 않도록 KEDA `maxReplicaCount`를 한시 하향합니다(예: 12→6, 조달 가능 슬롯 수준으로).

*필요성*: 용량 부족 시 이 조치가 없으면 **대기열이 잘못된 곳에 생깁니다** — 작업의 대기는 원래 큐의 일(순서·우선순위·재시도 의미론 보유)인데, KEDA가 max까지 선언한 수요가 공급을 초과하면 Pending Pod 더미가 K8s에 적체됩니다. 이 더미는 ① Karpenter가 채울 수 없는 수요를 향해 헛되이 재시도하게 만들고(ICE 이벤트 소음), ② "진짜 미충족 수요" 신호를 왜곡하며(분류기·알람·에스컬레이션 리포트의 입력 오염), ③ 용량 회복 순간 일제히 노드 생성을 요구하는 재확보 폭주(thundering herd)를 유발합니다. 큐 완충은 "선언된 수요"를 "조달 가능한 공급"에 정렬하여 — 워커는 풀가동, 초과분은 큐 대기 — 이 세 가지를 모두 차단합니다.

*한계와 성격*: **처리량은 1건도 늘지 않습니다** — 해결책이 아니라 "부족을 질서 있게 겪는" 위생 조치이며, SLO 방어는 게이트 개방(용량 확보)과 에스컬레이션(사람 판단)의 몫입니다. 대신 인프라 무접촉·즉시 가역·최악의 실패 모드가 "확장 지연"에 그치므로 폭발 반경이 4개 제어 항목 중 가장 작습니다 — 다른 시나리오와 항상 병행하는 후보이자, Shadow 모드 이후 write를 가장 먼저 활성화해도 되는 항목입니다. 하향 값은 "현재 Ready 워커 + 확보 전망" 근처로 산정하며, 회복 시 원복하면 KEDA가 큐 깊이 기준으로 점진 확장합니다(Pending 더미가 없으므로 폭주 없음).

**스택 복구** — "노드는 Ready인데 GPU 미광고" 및 patch 재부팅 후 검증 대응. 진단 체크리스트(PoC 실전 검증): `mig.config.state=failed`→프로파일명 확인 / `MIG-INVALID`→strategy 불일치 / 풀 GPU가 보이는 Pod→재생성. 액션은 라벨 원복·Pod 재생성·DaemonSet 재시작·(최후) NodeClaim 교체(인시던트당 2회 상한). **이 유형을 용량 실패로 오진하면 비용만 쓰고 해결되지 않으므로, 분류 가치가 가장 큰 시나리오입니다.**

**리전 확장 (리전 게이트, 계단식 병렬 개방)** — 서울의 상시 사다리가 소진되면 원격 리전 KEDA의 pause 어노테이션을 제거해 개방합니다(닫힘=`paused-replicas: "0"` 어노테이션, 개방=어노테이션 제거 — maxReplicaCount는 상한 역할로 상시 유지). 중앙 큐 토폴로지(§2.3) 덕분에 라우팅 변경이 불필요합니다 — 게이트가 열리면 해당 리전 KEDA가 같은 큐를 보고 워커를 요청하고, 그 리전의 Karpenter 사다리가 노드를 조달합니다.

*에스컬레이션 정책 (확정, 2026-09-16)* — 리전 우선 소진을 기본으로 하되, 각 단계에서 **"현재 리전 OD와 다음 리전 Spot을 동시 개방"**하는 계단식 병렬 구조를 채택합니다:

```
1단계: 서울 Spot (상시 사다리 — Karpenter 자동)
2단계: { 서울 OD  ∥ 도쿄 Spot }   동시 개방
3단계: { 도쿄 OD  ∥ 뭄바이 Spot } 동시 개방
4단계: 뭄바이 OD → 소진 시 에스컬레이션 (사람)
```

*동시 개방의 이유*: 순차 개방(서울 OD를 다 쓴 뒤에야 도쿄 Spot)에는 두 가지 문제가 있습니다. ① **비용 역전** — 실측 슬롯 단가 기준 서울 OD($2.07)는 도쿄 Spot($1.28)의 1.6배, 뭄바이 Spot($0.84)의 2.5배입니다. 비싼 풀을 먼저 소진하는 순서는 가격 서열과 역행합니다. ② **확보 확률** — 서울 Spot이 마른 상황에서는 서울 OD도 tight할 확률이 높습니다(공급 부족은 capacity-type을 가리지 않는 경향 — FRA 실측에서 확인된 패턴). 그렇다고 원격 Spot만 먼저 열면 중단 리스크에 무방비가 됩니다. **게이트들은 배타적이지 않으므로** 두 개를 동시에 열면: 안정성(OD의 무중단 용량)과 비용(원격 Spot의 저가 용량)을 함께 확보하고, 실제 어느 쪽이 채워질지는 Karpenter/KEDA의 결정론 계층이 가용성에 따라 자연 결정합니다. 복잡도 증가는 "한 단계에 게이트 2개"뿐이며, 원복은 여전히 역순입니다.

*리전 순서는 정책값입니다* — 현재 도쿄→뭄바이 순서는 고객 플랜을 따른 것이나, SPS 첫 측정(뭄바이 9점 vs 도쿄 3~5점, Spot 최저가)은 역순 우위를 시사합니다. 2~3주 추세(리전 순위 역전 패턴) 확보 후 재확정하며, 순서 변경은 아키텍처 무변경·정책표 수정만으로 가능합니다. 원복은 서울 회복(원복 안정 조건 충족) 시 역순으로 — 신규 유입 차단(max→0) 후 진행 중 작업의 grace 종료를 대기합니다. 가드레일: 단계당 예산 상한 · 전송 비용 인지 · 데이터 레지던시 사전 승인(정책값).

**구조화 에스컬레이션** — 액션 예산 소진·쿨다운 내 재발·HIGH 심각도 시, "시도한 것·결과·남은 옵션·비용"을 구조화한 리포트와 원클릭 승인(task token)으로 사람에게 위임합니다. 메모리 누수·성능 저하의 진단 결과 전달도 이번 단계에서는 이 경로를 사용합니다(재시작·롤백 권고 리포트).

### 4.2 차기 단계 시나리오 (요약 — 상세 설계는 이력 보존)

이번 단계의 제어 항목 4종으로 실행할 수 없거나, 위험·전제 조건이 커서 보류한 시나리오입니다. 신뢰 축적 후 단계적으로 도입합니다.

| 시나리오 | 보류 사유 |
| --- | --- |
| MIG 재구성으로 슬롯 확보 | 노드 재구성 필요 — 게이트 운영 안정화 후 |
| Time-slicing 강등 | 격리 상실(OOM 전파) — 승인 체계 성숙 후 |
| ODCR 확정 예약 | 유일한 비용 약정 항목 (2026-09-16 보류 결정) |
| 워크로드 품질 하향 | 앱 파라미터 제어 도구·품질 정책 합의 선행 |
| 리전 자세 최적화 (SPS slow loop) | 리전 확장의 고정 개방 순서(도쿄→뭄바이)를 추세 기반 동적 weight로 승격 — 캘리브레이션 데이터 축적 후 |

### 4.3 종합 실행 예제 — 계단식 병렬 개방과 원복 (Agent 액션 중심)

금요일 저녁 이벤트로 트래픽이 급증하는 상황을 끝까지 따라갑니다. 굵은 글씨가 Agent의 실제 액션입니다.

**[평시]** 서울 max=12·워커 6(g7e MIG 노드 3대), 도쿄/뭄바이는 pause 어노테이션으로 정지(게이트 닫힘, system 노드만).

**[19:00] 큐 급증 — Karpenter의 시간 (Agent 미개입)**
큐 60건 → 서울 KEDA desired=12 → 워커 Pod 12개 생성 시도 → 서울 Karpenter가 상시 사다리 순회: ① gpu-mig ICE → ② gpu-mig-large ICE → ③ gpu-g6e에서 2대 확보 후 ICE. 워커 9개 가동, 3개 Pending.

**[19:07] 알람 "상시 사다리 소진 5분 지속" → Agent 세션 1 (2단계 진입)**
- 판단: NodeClaim 이벤트 전 AZ ICE + SPS 서울 2점 + g6e Spot 시세가 OD의 90% 근접 → **리전 전체 부족 확정**
- **액션 1 (2단계 동시 개방)**: ① `서울 gpu-od limits "nvidia.com/gpu" 0→4 patch` (항목 #1) ∥ ② `도쿄 ScaledObject pause 어노테이션 제거 (max 상한 8)` (항목 #3, 멀티클러스터). 사전 체크: RBAC 화이트리스트 ✓, 단계 예산 +$17/hr ≤ 상한 $50/hr ✓, 도쿄 사전 조건(weight 복제·ECR·네트워크) ✓. DynamoDB 기록 + 원복 조건 등록
- 동작: 서울 OD NodeClaim 2대 확보 ∥ 도쿄 Karpenter가 Spot으로 g7e MIG 3대 조달(콜드스타트 ~6분) — **어느 쪽이 얼마나 채우는지는 결정론 계층이 가용성으로 결정** (이날은 도쿄 Spot이 먼저·많이 채움 — 비용상 유리한 결과)
- 검증: 10분 내 시스템 워커 12+6=18 → 큐 하강 시작 → 리포트: "2단계 개방, 서울 OD 2대 + 도쿄 Spot 6워커, +$14.9/hr 실효"

**[20:30] 트래픽 추가 급증 — 큐 250건, SLO 위반 임박 → Agent 세션 2 (3단계 진입)**
- 판단: 서울 OD 추가분·도쿄 Spot 모두 ICE 도달 → 3단계 조건 충족. SPS 조회: 뭄바이 9점 (여전히 최상위)
- **액션 2 (3단계 동시 개방)**: ① `도쿄 gpu-od limits 0→4` ∥ ② `뭄바이 pause 어노테이션 제거 (max 상한 8)`
- 검증: 뭄바이 Spot 4대(최저가 $0.84/슬롯) + 도쿄 OD 1대 → 시스템 워커 27 → 큐 하강
- 리포트: "3단계 개방. 누적 +$28/hr. 참고: 뭄바이가 2단계였다면 비용 -18% — 리전 순서 재검토 데이터 축적 중"

**[23:40] 큐 정상(<10건) 2시간 유지 + 서울 SPS 6점 회복 — 원복 안정 조건 충족 → 원복 (역순)**
- **액션 3**: ① 뭄바이 pause 재설정(0)·도쿄 gpu-od→0 (3단계 폐쇄 — 신규 차단, 기존 워커 grace 종료·미완료분 큐 반환) → 큐 안정 확인 후 ② 도쿄 max 8→0, 서울 gpu-od→0 (2단계 폐쇄) ③ 각 리전 노드는 WhenEmpty 30분 후 자연 회수
- 기록: 인시던트 총 추가 비용 $63(예산 내), [판정 근거·단계·결과·리전별 실효 단가]를 Memory 저장

이 예제에서 Agent가 만진 것은 **필드 4개**(서울·도쿄 게이트 limits, 도쿄·뭄바이 KEDA max)와 그 원복뿐입니다. 각 단계에서 두 게이트를 동시에 열되 실제 채움은 결정론 계층에 맡기는 것 — "Agent는 허가하고, 시장(가용성)이 배분한다"가 이 정책의 요지입니다.

---

## 5. Agent 제어 항목 — 확정 4종과 실행 계약

### 5.1 구성과 런타임 상태의 분리

| 계층 | 내용 | 변경 주체·빈도 | 저장소/경로 |
| --- | --- | --- | --- |
| 구조·정책 | 사다리 정의, 게이트 존재, limits 상한, weight 허용 범위, 원복 안정 조건 파라미터 | 사람, 월 단위 | Git/IaC (코드리뷰) |
| 런타임 posture | 어느 게이트가 열려 있나, 노드 보유 시간, 수요 완충 | **Agent**, 주 수 건 | DynamoDB 기록 + K8s 직접 patch |
| 실행 | posture → CR 반영 | 결정론 도구 Lambda | K8s API |

기각된 대안: ① patch/PR 두 경로 병행(GitOps self-heal과 자기모순) ② SPS 변화마다 Git 커밋(이력 오염·리뷰 형해화 — **환경 변화가 코드 변경을 유발해서는 안 됩니다**). GitOps 환경에서는 `ignoreDifferences`로 `spec.limits`만 런타임 소유 계약을 명시합니다. 구조 변경(리전 순위 역전에 따른 사다리 재정렬 등)은 Agent가 제안 리포트까지만 생성하고 사람이 기존 IaC 워크플로로 수행합니다.

### 5.2 확정 4종

공통 성질: **가역적 · Git 선언 상한 이내 · (스택 복구 제외) 신규 노드에만 영향**. 도구 Lambda는 대상 클러스터(서울/도쿄/뭄바이)를 파라미터로 받으며, 클러스터별 Access Entry·RBAC로 동일한 경계를 강제합니다. Agent가 직접 리소스를 생성·약정하는 액션은 없으며, 모든 항목은 "허가/한도" 조정입니다 — 실제 EC2 생성은 실수요와 Karpenter를 거쳐 조건부로만 발생합니다.

| # | 대상 | 필드 | 성질 | Git이 정하는 경계 | 주 사용 시나리오 |
| --- | --- | --- | --- | --- | --- |
| 1 | NodePool (게이트 풀만) | `spec.limits."nvidia.com/gpu"` | 풀 개폐 | 상한(예: 4=슬롯 4 — 광고 기준), RBAC resourceNames 화이트리스트 | 게이트 개방 |
| 2 | NodePool | `spec.disruption.consolidateAfter` | 확보 노드 보유 연장 | 최대 보유(예: 12h) | 노드 보유 연장 |
| 3 | KEDA ScaledObject | `spec.maxReplicaCount` + `paused-replicas` 어노테이션 | 수요 측 완충(max 조정) + **리전 게이트**(pause 설정/해제 — CRD가 max≥1 강제) | 허용 범위(예: 4~16) · 원격 리전 상한 별도 | 큐 완충 · 리전 확장 |
| 4 | Node/Pod (스택 복구 한정) | `nvidia.com/mig.config` 노드 라벨 원복, Pod 삭제/rollout restart | 스택 복구 | GPU 노드·지정 네임스페이스만 | 스택 복구 |

> **보류**: EC2NodeClass `capacityReservationSelectorTerms`(ODCR 연결)는 비용 약정이 따르는 유일한 항목이므로 차기 단계로 보류합니다.

**Agent가 변경하지 않는 것** (사람+Git 전용): `weight` · `requirements` · NodePool 템플릿 `mig.config` 라벨 · AMI · taint.

### 5.3 명령 전달 체인과 3중 가드레일

```
Agent plan(JSON) → [SFN Execute] → write 도구 Lambda
   ① 파라미터 재검증 (화이트리스트·상한 — LLM 출력 불신)
   ② EKS Access Entry로 K8s 토큰 획득
   ③ PATCH /apis/karpenter.sh/v1/nodepools/<name>
→ Karpenter가 다음 reconcile부터 적용 (수 초)
```

가드레일: AgentCore Policy(도구·파라미터) → Lambda 코드 재검증 → **K8s RBAC** (`resourceNames`에 게이트 풀만 — 상시 사다리는 구조적으로 불가침).

### 5.4 실행 예제 (요지)

| 예제 | 상황 → 액션 → 원복 |
| --- | --- |
| A. 게이트 개방 (항목 #1) | 상시 사다리 소진(리전 전체 부족) → `gpu-od` limits 0→4 patch → 6h 후 타이머 원복, 잔여 노드 자연 회수 |
| B. 노드 보유 (항목 #2) | 점수 ≤3 6시간 지속 → `consolidateAfter` 30m→4h → 회복(원복 안정 조건 충족) 시 복원 |
| C. 큐 완충 (항목 #3) | 용량 부족 중 Pending 누적 방지 → `maxReplicaCount` 12→6 → 회복 시 복원 |
| D. 스택 복구 (항목 #4) | `mig.config.state=failed` → 라벨 직전 정상값 원복(재분할 ~40초) → 오염 Pod 재생성. 영구 조치(ConfigMap 수정)는 사람 몫으로 리포트 |

### 5.5 공통 실행 계약 (4종 전부 적용)

```
변경 전: DynamoDB에 [현재값, 목표값, 근거, 원복예정시각] 기록
변경 시: Git 선언 상한/화이트리스트 내에서만 (Lambda 코드 + RBAC 이중 강제)
변경 후: 10분 내 효과 검증 → 무효면 원복 + 다음 사다리
원복:   모든 변경에 타이머 또는 회복-조건 원복이 반드시 짝으로 존재
```

---

## 6. 정책 골격 — 단일 Agent의 2모드 구조

하나의 Strands Agent(AgentCore Runtime)가 두 호출 모드로 전체를 커버합니다. 두 모드는 제어 항목·가드레일·Memory를 공유하되, **트리거와 액션 예산은 분리**합니다 (posture 판단이 인시던트 예산을 소모하지 않도록).

```
[모드 A — 인시던트 대응 (알람 트리거: Gate → SFN → classify→investigate→plan→execute→verify)]
   [분류] 확보 실패 7유형 + 워커 이상 3유형 통합 판별 — 오진 방지가 최우선
      쿼터 초과 → 재시도 중단 + 여유 있는 경로로 전환
      GPU 미광고·재부팅 후 검증 → 용량 대응 실행 금지, 스택 복구
      메모리 누수·성능 저하 → 워크로드 진단 → 재시작/롤백 권고
   [병행] 큐 완충은 항상 즉시 병행
   [게이트] 상시 사다리 소진 확증 시에만 고비용 풀 개방 (게이트 개방)
   [리전] 계단식 병렬 개방 (리전 확장): 2단계 {서울 OD ∥ 도쿄 Spot} → 3단계 {도쿄 OD ∥ 뭄바이 Spot}
          → 4단계 뭄바이 OD → 에스컬레이션. 리전 순서는 정책값 (SPS 추세로 재확정 예정)
   [승인/차기] 강등·품질 하향은 차기 단계 — 이번 단계에서는 에스컬레이션 리포트로 사람에게 위임
[모드 B — posture 관리 (Scheduler 트리거, 15~30분 slow loop)]
   용량 추세 6패턴 해석 (교차 확증 필수) → 게이트 준비도·노드 보유 시간 조정
   → 리전 weight 재계산(리전 자세 최적화)은 차기 단계 — 현재는 SPS Tracker 데이터 축적
[0계층 — 사전 구성 (Agent 무관, IaC/운영 프로세스)]
   사다리 선언 · 쿼터 행렬 사전 증설+자동 요청 · 전 타입 이미지 CI · 품질 정책 합의
[1계층 — Karpenter 자동 (수 초~수십 초)]
   가용영역 재시도 → 상시 사다리 폴백 — Agent는 이 계층 소진 후에만 개입
[가드레일 공통]
   쿨다운(동일 클래스 30분) · 예산(인시던트당 액션 3회 + 비용 상한)
   · 검증(10분 내 효과 측정) · 기록(Memory + DynamoDB 감사 로그) · 최후엔 에스컬레이션
```

---

## 7. 실행 아키텍처 — AgentCore + Strands (확정, 2026-09-16)

상세 설계 변천(v1→v3)은 `agent-architecture-agentcore-strands.md`에 보존하며, 본 절은 확정 아키텍처의 요지입니다. **다이어그램**: `gpu-agent-architecture-v3.drawio`

### 7.1 전체 구조

```
[트리거]                  [게이트·오케스트레이션]              [Agent (판단)]           [실행·대상]

CloudWatch Alarms ──→ EventBridge → SQS → Lambda Gate → Step Functions
                   │   (알람 상태전이만)  (중복제거·쿨다운·      │
EventBridge        │                    예산·컨텍스트번들)     ├ Investigate ─(비동기 task-token)→ AgentCore Runtime
Scheduler ─────────┘                                          │                                  Strands Graph:
 (posture 15~30분)                                            │                                  classify→investigate→plan
운영자 → InvokeAgentRuntime 직접 (동기) ───────────────────────┤                                    │ read 도구만 (Gateway/MCP)
                                                              ├ Choice(risk) ─ HIGH → Approve (waitForTaskToken 무과금 HITL)
                                                              ├ Execute → write Lambda 4종 (Agent 미경유)
                                                              │            → 서울/도쿄/뭄바이 EKS (Access Entry+RBAC)
                                                              ├ Verify (10분 효과 측정, 무효→재계획 ≤3회)
                                                              └ Report → SNS/티켓 + Memory + 원복 스케줄
```

### 7.2 Invoke 경로 3가지 — 하나의 비동기 계약

- **경로 A (인시던트)**: 알람 상태전이 → EventBridge → SQS → Gate(결정론 방어선) → SFN → Investigate 상태가 `InvokeAgentRuntime(runtimeSessionId=hash(incident_id), payload={mode, incident_id, task_token, context_bundle})`로 **비동기 호출**. Strands entrypoint는 token 존재 시 백그라운드 Graph를 시작하고 즉시 "accepted"를 반환하며, SFN은 무과금 일시정지(Timeout+Heartbeat)합니다. Graph 완료 시 `SendTaskSuccess(plan JSON)`으로 SFN이 재개됩니다. 세션 ID의 incident_id 파생과 SFN 실행명 유일성이 멱등성을 이중 보장합니다.
- **경로 B (posture)**: Scheduler 15~30분 → 동일 Gate(`mode=posture`, **인시던트와 예산 분리**) → 같은 Runtime의 용량 추세 분기. 이번 단계 posture의 write는 제어 항목 #2(consolidateAfter)로 한정됩니다.
- **경로 C (운영자)**: token 없는 직접 호출 = 동기 응답 — Shadow 모드 검증·사후 분석(Memory 조회) 용도입니다.

### 7.3 도구 사용 — read/write 비대칭

**read 3종 (Agent가 직접, AgentCore Gateway/MCP 경유)**:

| 도구 | 파라미터 | 용도 |
| --- | --- | --- |
| `k8s_read` | **cluster ∈ {seoul, tokyo, mumbai}**, 리소스 | NodeClaim/NodePool/Pod/이벤트 조회 — **NodeClaim 이벤트의 에러 코드(ICE/쿼터)가 확보 실패 판별의 근거** |
| `cloudwatch_read` | 네임스페이스·기간 | SPS Tracker(용량 추세), 슬롯별 DCGM(워커 이상 징후), 큐 깊이 |
| `spot_price_read` | 리전·타입 | 가격 역전 판정·비용 추정 |

> **CloudTrail 연동 제외 (2026-09-16 결정)**: 확보 실패 판별에 필요한 에러 코드(`InsufficientInstanceCapacity`, `VcpuLimitExceeded` 등)는 Karpenter가 NodeClaim 이벤트/상태에 그대로 노출하므로, CloudTrail 트리거·조회 도구는 이번 단계에서 제외합니다 — 연동 표면과 IAM 권한이 줄어듭니다.

Identity가 도구별 최소권한 IAM을, Policy가 파라미터 수준 인가를 강제하며, read 도구는 **classify/investigate 노드에만 바인딩**되어 "조사 없이 액션" 경로가 구조적으로 차단됩니다 (investigate 도구 호출 상한 ~20회).

**write 4종 (Agent가 호출하지 않음 — SFN Execute가 직접)**: Agent 산출물은 plan JSON(`{scenario, actions:[{tool, cluster, params}], risk, budget_est, rollback}`)까지이며, 실행은 SFN이 write Lambda를 직접 호출합니다. **write 도구는 Gateway에 등록하지 않아 Agent가 호출할 표면 자체가 없습니다.** 4종은 §5.2의 제어 항목과 1:1이고(`patch_nodepool_limits` / `patch_consolidate_after` / `patch_keda_max` / `recover_gpu_stack`), 각각 Lambda 코드 재검증 → 클러스터별 Access Entry → K8s RBAC resourceNames의 3중 경계를 거칩니다. 계단식 병렬 개방(§4.1 리전 확장)은 SFN **Parallel 상태**로, 원복은 Scheduler 등록으로 Agent 재개입 없이 실행됩니다.

### 7.4 AgentCore 컴포넌트

| 컴포넌트 | 구성 |
| --- | --- |
| Runtime | Strands 앱 컨테이너 1개 (2모드 공용), 세션=incident_id 해시 |
| Gateway | read 도구 3종만 등록 |
| Identity / Policy | 도구별 최소권한 + 파라미터 수준 인가 |
| Memory | 단기(세션 조사) + 장기(인시던트→판정→액션→결과·리전별 실효 단가) |
| Observability | OTEL→CloudWatch — Shadow 모드 분류 정확도 채점·tool call 감사 |

---

## 8. MVP 로드맵과 고객 시나리오 매핑

**MVP = 분류기(확보 실패 + 워커 이상) + Top 3**: ① **스택 복구** (PoC 검증 플레이북, 저위험) ② **게이트 개방+비용 예산** (유일한 write가 limits patch로 한정) ③ **구조화 에스컬레이션** (신뢰 기반).
**롤아웃**: Shadow 모드(권고 리포트만, 분류 정확도 측정 2주) → 스택 복구·큐 완충 write 활성화 → 게이트 개방 + 모의 용량 부족 게임데이 → **리전 확장 게이트** (전제 인프라 §2.3 완비 + 게임데이에서 서울 소진 시나리오 검증 후). 노드 보유 연장은 posture 모드와 함께, 차기 시나리오(§4.2)는 신뢰 축적 후, ODCR 예약은 별도 재검토.

고객 프레임(#1 수요 예측·용량 / #2 장애 대응) 번역:

| 고객 프레임 | 내부 매핑 | MVP 기여 |
| --- | --- | --- |
| **#1 용량 확보** — "밖에서 구해오는 문제" | 확보 실패 유형 전반 / 게이트 개방·리전 확장 / 용량 추세·노드 보유 연장 | 게이트 개방+비용 관리 = #1의 첫 구현 사례 |
| **#2 장애 대응** — "안에서 고치는 문제" | GPU 미광고·워커 이상 / 스택 복구 / 에스컬레이션 | 스택 복구 = #2의 첫 구현 사례 |

---

## 부록

### 부록 A. 사다리 동작 트레이스

**평시 동작** (Agent 미개입): Pod Pending → Karpenter가 weight 순으로 시도합니다 —

```
① gpu-mig(100)에서 g7e Spot 시도 → ICE
② gpu-mig-large(90)로 자동 폴백 → ICE
③ gpu-g6e(80)로 자동 폴백 → 성공! (여기까지 수 초~수십 초, 전부 자동)
④⑤ gpu-od/gpu-p4de는 limits=0이라 Karpenter가 후보에서 제외 — 시도 자체를 안 함
```

**게이트 개방 시** (①~③ 전부 소진 = 리전 수준 용량 부족으로 확정, Agent 판단):

```
Agent가 gpu-od의 limits(nvidia.com/gpu)를 0→4 patch
→ 다음 reconcile부터 ④가 후보에 편입 → OD 슬롯 4개(g7e MIG 노드 2대) 생성 가능
→ 6시간 후 원복 타이머가 limits를 0으로 → 신규 생성 차단, 기존 노드는 비면 자연 회수
```

핵심은 다음과 같습니다: **①~③의 폴백은 Karpenter의 내장 동작**(weight)이므로 Agent가 필요하지 않고, **④~⑤의 개폐만이 Agent의 역할**(비용 판단)입니다 — "결정론은 Karpenter에게, 판단은 Agent에게"라는 원칙이 이 표 하나에 구현되어 있습니다.

### 부록 B. NodePool YAML (사다리 원형 3종)

아래 3개가 사다리의 원형(archetype)이며 나머지 풀은 같은 패턴의 변형입니다. (PoC 검증된 구성 기준 — `karpenter.sh/v1`, EC2NodeClass는 공용 `gpu-mig` 사용 가정)

```yaml
# ── ① 상시·기본: g7e Spot + MIG (weight 100) ──────────────────────
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-mig
spec:
  weight: 100                          # 사다리 최우선
  template:
    metadata:
      labels:
        node-role: gpu
        nvidia.com/mig.config: all-2g.48gb   # MIG Manager 트리거 → 48GB×2 분할
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu-mig }
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g7e.2xlarge", "g7e.4xlarge", "g7e.8xlarge"]  # 사이즈 다변화
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
      taints:
        - { key: nvidia.com/gpu, value: "true", effect: NoSchedule }
      expireAfter: Never
  limits:
    nvidia.com/gpu: "8"                # 광고 슬롯 8 = g7e MIG 노드 4대 예산 = 상시 열림
                                       # (사이즈 혼합 풀은 cpu보다 gpu 키가 예산을 정확히 묶음 — 단 MIG 분할 배수 주의)
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m              # ← Agent 제어 항목 #2 (SPS 지속 저점 시 4h로 연장)
---
# ── ③ 상시·대체 타입: g6e Spot 풀 GPU (weight 80) ─────────────────
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-g6e
spec:
  weight: 80                           # g7e 계열 소진 시에만 선택됨
  template:
    metadata:
      labels:
        node-role: gpu                 # MIG 라벨 없음 — L40S는 MIG 미지원, 풀 GPU 1슬롯
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu-mig }
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g6e.2xlarge", "g6e.4xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
      taints:
        - { key: nvidia.com/gpu, value: "true", effect: NoSchedule }
      expireAfter: Never
  limits:
    nvidia.com/gpu: "8"                # g6e는 노드당 1슬롯 — 8대 예산
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m
---
# ── ④ 게이트: On-Demand (weight 60, 평시 잠김) ────────────────────
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-od
spec:
  weight: 60
  template:
    metadata:
      labels:
        node-role: gpu
        nvidia.com/mig.config: all-2g.48gb
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu-mig }
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["g7e.2xlarge", "g7e.4xlarge", "g6e.2xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]        # Spot 프리미엄 소멸 상황용
      taints:
        - { key: nvidia.com/gpu, value: "true", effect: NoSchedule }
      expireAfter: Never
  limits:
    nvidia.com/gpu: "0"                # ★ 게이트 닫힘 (Git 선언 안전 기본값)
                                       #   Agent가 리전 용량 부족 확정 시 "4"로 patch — 제어 항목 #1
                                       #   (광고 슬롯 4 — g7e MIG 노드 2대 또는 g6e 4대)
                                       #   Git 선언 상한(4)을 Lambda가 강제
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m
```

Pod 측은 사다리 구성을 전혀 알 필요가 없습니다 — `nvidia.com/gpu: 1` 요청 + `node-role: gpu` nodeSelector + toleration만 있으면, 어느 풀의 노드에 배치되든 동일하게 동작합니다 (MIG 슬라이스든 풀 GPU든 리소스명이 같음 — device plugin `single` 전략).

### 부록 C. 실행 예제 상세 (kubectl 명령 포함)

### 예제 A — 리전 용량 부족: 게이트 개방 (제어 항목 #1)

```
19:07 서울 상시 사다리(g7e→g6e) 소진 — 리전 수준 용량 부족으로 확정
Agent plan: {"tool":"patch_nodepool_limits","name":"gpu-od","gpu":"4","revert_after":"6h"}

kubectl patch nodepool gpu-od --type merge -p '{"spec":{"limits":{"nvidia.com/gpu":"4"}}}'
  체크: gpu-od ∈ RBAC 화이트리스트 ✓ / 4 ≤ Git 상한 ✓
효과: OD 슬롯 4개(g7e MIG 노드 2대) 생성 허용 (기존 노드 무영향)
원복: 6h 후 Scheduler → {"nvidia.com/gpu":"0"} → 잔여 노드 WhenEmpty 자연 회수
```

### 예제 B — SPS 지속 저점: 확보 노드 보유 (제어 항목 #2)

```
서울 score ≤3 6h 지속 — "지금 가진 노드가 귀하다"
kubectl patch nodepool gpu-mig --type merge \
  -p '{"spec":{"disruption":{"consolidateAfter":"4h"}}}'   # 평시 30m → 4h
효과: 큐가 잠시 비어도 노드 보유 — 반납 후 재확보 실패 위험 회피
원복: 점수 회복(원복 안정 조건 충족) 시 30m 복원
비고: 유일하게 기존 노드 수명에 작용하나 "회수 지연" 방향이라 fail-safe
```

### 예제 C — 큐 적체 완충 (제어 항목 #3)

```
kubectl patch scaledobject inference-worker -n inference --type merge \
  -p '{"spec":{"maxReplicaCount":6}}'    # 평시 12 → 한시 6
효과: 확보 불가능한 replica를 요구하며 Pending 쌓는 것 방지
원복: 용량 회복 시 12 (Git 선언 범위 4~16 내에서만)
```

### 예제 D — GPU 스택 장애 복구 (제어 항목 #4): 노드는 Ready이나 GPU 미광고

```
노드 Ready ∧ allocatable gpu=0, mig.config.state=failed (config 오타 배포)
① kubectl label node <node> nvidia.com/mig.config=all-2g.48gb --overwrite  # 직전 정상값
② state=success 확인 (실측 ~40초)
③ kubectl delete pod <MIG 적용 전 기동 pod>  # 재생성으로 슬라이스 재할당
효과: 노드 교체 없이 복구. 영구 조치(ConfigMap 수정)는 사람 몫으로 리포트
```

### 예제 E — 리전 확장: 원격 리전 게이트 개방 (제어 항목 #1+#3, 계단식 병렬)

```
19:07 서울 상시 사다리 소진 = 2단계 진입 — {서울 온디맨드 ∥ 도쿄 Spot} 동시 개방
Agent plan: {"actions":[
  {"tool":"patch_nodepool_limits","cluster":"seoul","name":"gpu-od","gpu":"4"},
  {"tool":"patch_keda_max","cluster":"tokyo","name":"inference-worker","action":"unpause","max":8}
], "revert_after":"6h"}   ← SFN Execute가 Parallel 상태로 두 write Lambda 동시 호출

# 브랜치 ① 서울 클러스터 (예제 A와 동일)
kubectl --context seoul patch nodepool gpu-od --type merge \
  -p '{"spec":{"limits":{"nvidia.com/gpu":"4"}}}'

# 브랜치 ② 도쿄 클러스터 — 리전 게이트 개방 (pause 해제)
kubectl --context tokyo annotate scaledobject inference-worker -n inference \
  autoscaling.keda.sh/paused-replicas-        # 어노테이션 제거 = 오토스케일 재개
  체크: max 상한 8 ≤ 원격 리전 상한(Git 선언) ✓ / 사전 조건: ECR 복제·중앙 큐 네트워크 경로 ✓
  (KEDA CRD가 maxReplicaCount ≥ 1을 강제 — "max=0 게이트"는 불가, pause 어노테이션이 공식 메커니즘)

효과: 도쿄 KEDA가 같은 중앙 큐의 깊이를 보고 워커 생성 시작
  → Pending → 도쿄 Karpenter가 자기 사다리로 노드 조달 (콜드스타트 ~6분)
  → 서울 온디맨드와 도쿄 Spot 중 어느 쪽이 채울지는 가용성이 결정 (Agent는 허가만)
  라우팅 변경 없음 — 3리전이 같은 큐를 소비하므로 게이트 개폐가 곧 리전 선택

3단계 (필요 시): {도쿄 gpu-od 0→4 ∥ 뭄바이 pause 해제} — 같은 패턴 반복

원복 (서울 회복, 원복 안정 조건 충족 시 — 역순):
kubectl --context tokyo annotate scaledobject inference-worker -n inference \
  autoscaling.keda.sh/paused-replicas="0" --overwrite   # 정지 + replica 0
  ★ 주의: pause(0) 시 기존 워커도 축소로 종료됨 — graceful shutdown에서
    처리 중 작업을 큐에 반환(re-push)하는 워커 패턴이 전제 (§2.3 전제 ③)
  → 워커 종료 후 도쿄 노드는 WhenEmpty 30분 뒤 자연 회수 (리전 유지비 = system 노드만)
```

