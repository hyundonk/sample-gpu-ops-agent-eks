# =============================================================================
# gpu-operator.tf — NVIDIA GPU Operator (Device Plugin 경로, DRA 미사용)
# =============================================================================
# GPU Operator는 GPU 노드에 필요한 소프트웨어 스택 전체를 DaemonSet으로
# 자동 관리하는 오퍼레이터다. 노드 라벨(NFD가 부착)을 보고 GPU 노드에만
# 컴포넌트를 배치한다:
#
#   NFD(Node Feature Discovery) ─ 하드웨어 감지, 노드 라벨링
#   GFD(GPU Feature Discovery) ── GPU 상세정보를 노드 라벨로 노출
#   MIG Manager ───────────────── nvidia.com/mig.config 라벨 감시 → GPU 분할
#   Device Plugin ─────────────── GPU(또는 MIG 슬라이스)를 kubelet에
#                                 nvidia.com/gpu 리소스로 광고 ★핵심
#   DCGM Exporter ─────────────── GPU 메트릭 (MIG 인스턴스별 관측 가능)
#
# values 설계 근거 (heredoc 내부 diff 방지를 위해 여기서 설명):
#   driver.enabled=false / toolkit.enabled=false
#     → AL2023 NVIDIA AMI에 드라이버·container toolkit이 사전설치되어 있음.
#       중복 설치하면 노드가 깨진다 (블로그 "AL2023 AMI quirks" 교훈)
#   devicePlugin.enabled=true
#     → 참조 블로그는 DRA를 쓰느라 껐지만, 우리는 고전적(검증된) 경로 사용
#   mig.strategy=single
#     → 노드 내 모든 MIG 슬라이스가 동일 프로파일일 때 사용.
#       슬라이스가 평범한 nvidia.com/gpu 리소스로 광고됨 (Pod는 gpu: 1 요청).
#       이종 프로파일(all-balanced 등)이면 mixed 필요 — 잘못 맞추면
#       노드가 MIG-INVALID 라벨과 함께 GPU 0개로 광고되는 함정 주의
#   migManager.env WITH_REBOOT=true
#     → g7e는 MIG 모드 전환에 GPU reset(경우에 따라 재부팅)이 필요.
#       실측에서는 GPU가 idle이라 재부팅 없이 40초 만에 완료됨
#   migManager.config.name=custom-mig-config
#     → 기본 제공 ConfigMap(default-mig-parted-config)에 RTX PRO 6000
#       Blackwell(GB202) 항목이 없을 수 있어 커스텀 ConfigMap 사용
#       (gpu-ladder 차트가 생성). default=all-disabled: 라벨 없는 노드는
#       MIG 비활성이 기본
#   daemonsets.tolerations
#     → GPU 노드에 nvidia.com/gpu:NoSchedule taint를 걸어뒀으므로,
#       GPU Operator의 DaemonSet들이 그 노드에 뜰 수 있게 toleration 부여
# =============================================================================

resource "helm_release" "gpu_operator" {
  namespace  = "gpu-operator"
  name       = "gpu-operator"
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  version    = var.gpu_operator_version

  # Daemonsets stay Pending until the GPU node exists — don't block apply
  # (GPU 노드는 나중에 Karpenter가 수요 발생 시 만들기 때문)
  wait = false

  values = [
    <<-EOT
    driver:
      enabled: false
    toolkit:
      enabled: false
    devicePlugin:
      enabled: true
    mig:
      strategy: single
    migManager:
      enabled: true
      env:
        - name: WITH_REBOOT
          value: "true"
      config:
        name: custom-mig-config
        default: all-disabled
    nfd:
      enabled: true
    dcgmExporter:
      enabled: true
    operator:
      defaultRuntime: containerd
    daemonsets:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
    EOT
  ]

  # gpu_ladder creates the gpu-operator namespace and custom-mig-config —
  # 참조하는 ConfigMap이 먼저 존재해야 MIG Manager가 정상 기동
  depends_on = [helm_release.gpu_ladder]
}
