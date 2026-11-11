# MIG (Multi-Instance GPU) — Mixed 모드 GitOps 구성

DGX B300(GPU 8장) 중 4장을 MIG 로 나누고 4장은 통 GPU 로 쓰는 구성을 GitOps 로 관리하기 위한 틀이다.
**테스트 클러스터에는 적용하지 않는다** (RTX 3060, `nvidia.com/mig.capable=false`).
Argo CD 앱 `../gitops/apps/05-kbl-ops-mig.yaml` 은 파일 전체가 주석이라 동기화되지 않는다.

> 근거: RHOAI 3.5 문서는 MIG 를 *Working with accelerators* 의 time-slicing 비교로만 언급한다.
> 아래 MIG 동작(mig-manager, 라벨, 재분할 절차)은 NVIDIA GPU Operator 기준이며 **3.5 미확인**이다.
> 프로파일 이름(`1g.35gb`, `3g.140gb`)은 예시다. B300 실물에서 `nvidia-smi mig -lgip` 로 확인해 바꾼다.

## 구조 (3개 층)

| 층 | 파일 | 내용 | 담당 |
|---|---|---|---|
| 1. MIG 전략 | `00-clusterpolicy-mig-mixed.yaml` | ClusterPolicy `mig.strategy: mixed`, `migManager.config.name: custom-mig-config` | 플랫폼 (Ops) |
| 2. 분할 구성 | `10-mig-config.yaml` | ConfigMap `custom-mig-config` — GPU 별 프로파일 (mig-parted 형식) | 플랫폼 (Ops) |
| | `20-node-labels.yaml` | 노드 라벨 `nvidia.com/mig.config=<구성 이름>` — 노드가 어떤 구성을 쓸지 | 플랫폼 (Ops) |
| 3. 소비 | `30-hardwareprofile-mig.yaml` | MIG 조각 HardwareProfile (identifier = `nvidia.com/mig-<프로파일>`) | Ops |
| | `40-resourcequota-mig.yaml` | 모델 네임스페이스의 MIG 조각 상한 (예시) | Ops |
| | (AI 폴더) | 모델 `resources` 에 MIG 리소스 요청 | AI |

예시 구성 `dgx-b300-half-mig`:

| GPU | 모드 | 노출 리소스 | 용도 |
|---|---|---|---|
| 0, 1 | MIG `1g.35gb` × 7 | `nvidia.com/mig-1g.35gb` (14개) | 소형 모델, 임베딩 |
| 2, 3 | MIG `3g.140gb` × 2 | `nvidia.com/mig-3g.140gb` (4개) | 중형 모델 |
| 4–7 | 통 GPU | `nvidia.com/gpu` (4개) | 대형 모델, tensor parallel |

Mixed 모드에서는 이렇게 같은 노드에 MIG 조각과 통 GPU 가 함께 노출된다 (single 모드는 노드의 모든 GPU 가 같은 프로파일).

### ClusterPolicy 소유권 주의
테스트 클러스터의 ClusterPolicy 는 openshift-cluster-gitops 리포(Argo 앱 `nvidia-gpu-operator`)가 관리하고,
그 리포에 같은 역할의 `components/operators/gpu-operator-certified/instance/components/mig-mixed` 가 있다.
**`mig` / `migManager` 필드는 한 곳에서만 관리한다.** 플랫폼 리포에서 관리한다면 `00-clusterpolicy-mig-mixed.yaml` 을 지우고
그쪽 overlay 에 `mig-mixed` 컴포넌트와 `migManager.config` 를 추가한다. 두 앱이 같은 필드를 쓰면 서로 되돌린다.

## 모델에서 쓰는 법 (AI팀)

```yaml
# LLMInferenceService (deploy/ai/maas/<모델>.yaml)
spec:
  template:
    containers:
      - name: main
        resources:
          limits:
            nvidia.com/mig-1g.35gb: "1"     # nvidia.com/gpu 대신 MIG 리소스 이름
          requests:
            nvidia.com/mig-1g.35gb: "1"
```
- MIG 조각 하나는 독립된 GPU 처럼 보인다 (메모리·장애 격리). 조각 여러 개로 tensor parallel 은 하지 않는다 — 큰 모델은 통 GPU 를 쓴다
- vLLM `--gpu-memory-utilization`, `--max-model-len` 을 조각 메모리에 맞춘다
- ISVC 라면 `opendatahub.io/hardware-profile-name: mig-1g-35gb` 로 프로파일을 고를 수 있다

## MIG 구성을 바꾸면 일어나는 일

1. 노드 라벨 `nvidia.com/mig.config` 값(또는 그 구성의 내용)이 바뀐다
2. mig-manager 가 노드에 `nvidia.com/mig.config.state=pending` 을 붙인다
3. 그 노드의 GPU operand(device-plugin, gpu-feature-discovery, dcgm-exporter)를 멈추고 GPU 를 다시 나눈다
   - **GPU 를 쓰는 사용자 파드가 있으면 재분할이 실패하거나 대기한다** (MIG 인스턴스를 지울 수 없음)
   - GPU·펌웨어에 따라 MIG 모드 전환에 **GPU 리셋이나 노드 재부팅**이 필요할 수 있다
4. 끝나면 `nvidia.com/mig.config.state=success` (실패 시 `failed`), operand 가 다시 뜨고 노드 allocatable 이 새 리소스로 바뀐다
5. 없어진 리소스 이름을 요청하는 모델 파드는 **Pending** (스케줄 불가). HardwareProfile·quota 가 새 이름과 다르면 배포가 거부된다

→ MIG 변경은 **노드 유지보수 작업**이다. Git 커밋만으로 끝나지 않고 순서와 확인이 필요하다.

## 변경 절차

예: GPU 2,3 을 `3g.140gb × 2` → `2g.70gb × 3` 으로 바꾼다.

**PR 1 — 영향 받는 모델 내리기 (AI팀, Ops 확인)**
```bash
# 그 노드에서 MIG/GPU 를 쓰는 파드 확인
oc get pods -A -o wide --field-selector spec.nodeName=<노드> | grep -v -E 'nvidia-gpu-operator|openshift-'
```
해당 모델의 `replicas: 0`(LLMISVC) 또는 `serving.kserve.io/stop: "true"`(ISVC) 커밋 → sync → 파드 종료 확인

**PR 2 — MIG 구성 변경 (Ops)**
1. `10-mig-config.yaml` 에 새 구성(예: `dgx-b300-half-mig-v2`)을 **추가**한다 (기존 구성을 고치지 말고 새 이름으로 — 롤백이 쉽다)
2. `20-node-labels.yaml` 의 라벨 값을 새 구성 이름으로 바꾼다
3. 커밋 후 Argo CD 에서 `kbl-ops-mig` 를 **수동 Sync**
4. 완료 대기
   ```bash
   oc get node <노드> -L nvidia.com/mig.config,nvidia.com/mig.config.state -w     # success 가 될 때까지
   oc describe node <노드> | grep -A15 Allocatable | grep nvidia.com                # 새 리소스 이름·개수
   oc logs -n nvidia-gpu-operator -l app=nvidia-mig-manager --tail=50            # 실패 시
   ```

**PR 3 — 소비 쪽 맞추기 (Ops → AI)**
1. `30-hardwareprofile-mig.yaml`, quota 를 새 리소스 이름으로 (Ops)
2. 모델 `resources` 를 새 리소스 이름으로 바꾸고 `replicas` 복원 (AI)
3. 모델 Ready, MaaS 호출 확인

**롤백**: 라벨을 이전 구성 이름으로 되돌리고 같은 절차 (구성을 새 이름으로 추가했기 때문에 가능)

## 운영 규칙

- `kbl-ops-mig` 앱은 **automated sync / selfHeal 을 켜지 않는다.** 켜 두면 누가 라벨을 손으로 바꿨을 때 Argo 가 되돌리면서
  예고 없이 재분할(=모델 중단)이 일어난다
- Node 매니페스트는 라벨만 담고 `Delete=false,Prune=false` — Argo 가 노드를 지우는 일이 없게 한다
- 구성 이름은 버전처럼 바꾼다 (`...-v2`). 기존 구성 내용을 고치면 같은 라벨을 쓰는 노드가 의도치 않게 재분할될 수 있다
- HardwareProfile identifier, quota 리소스 이름, 모델 resources 는 노드 allocatable 이름과 **문자 그대로** 같아야 한다
- 노드가 여러 대면 노드마다 라벨 문서를 두고 한 번에 한 노드씩 바꾼다 (모델 replica 를 다른 노드로 옮겨 무중단)

## 활성화 (실제 B300 클러스터)

1. 프로파일 이름 확인: `oc debug node/<노드> -- chroot /host nvidia-smi mig -lgip` (또는 driver 파드에서)
2. `10-mig-config.yaml`, `20-node-labels.yaml`(노드 이름), `30`, `40` 을 사이트 값으로 수정
3. ClusterPolicy 를 어느 리포가 관리할지 정한다 (위 "소유권 주의")
4. `../gitops/apps/05-kbl-ops-mig.yaml` 주석 해제 → 커밋 → `kbl-root` 가 앱 생성 → 위 변경 절차로 수동 Sync
