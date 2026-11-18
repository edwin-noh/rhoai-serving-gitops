# DGX B300 MIG 적용 방법

[`DGX_B300_MIG_모델할당.md`](../../DGX_B300_MIG_모델할당.md) 계획을 GitOps 로 적용하는 순서다.
MIG 동작(mig-manager, 노드 라벨, 재분할)은 NVIDIA GPU Operator 기준이며 RHOAI 3.5 문서에는 없다 (**3.5 미확인**).
프로파일 이름·크기는 [NVIDIA MIG User Guide — Supported MIG Profiles](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/supported-mig-profiles.html) 의 B300 288GB 표 기준.

## 0. 적용할 구성 (`kbl-dgx-b300-v1`)

| GPU | MIG 구성 | 용도 |
|---|---|---|
| 0, 1 | `2g.67gb`×1 + `1g.34gb`×4 + `1g.67gb`×1 | OCR VLM1 · OCR VLM2 ×2 / Embedding·Reranker / 예비 · OCR worker |
| 2, 3, 4 | `2g.67gb`×3 + `1g.67gb`×1 | AI Agent ×3 · RAG |
| 5 | `2g.67gb`×3 + `1g.67gb`×1 | Scale-out buffer (모델 미할당) |
| 6, 7 | MIG 끔 | 통 GPU |

- 계획서의 `1g.31` / `1g.63` / `2g.63` 은 실제 이름 `1g.34gb` / `1g.67gb` / `2g.67gb` 로 쓴다
- 두 조합 모두 메모리 8조각·SM 7조각을 정확히 채운다

적용 후 노드에 나타나야 하는 리소스:

| 리소스 | 개수 |
|---|---|
| `nvidia.com/mig-2g.67gb` | 14 |
| `nvidia.com/mig-1g.67gb` | 6 |
| `nvidia.com/mig-1g.34gb` | 8 |
| `nvidia.com/gpu` | 2 |

관련 파일: `10-mig-config.yaml`(구성), `20-node-labels.yaml`(노드가 쓸 구성), `30-hardwareprofile-mig.yaml`, `40-resourcequota-mig.yaml`,
`00-clusterpolicy-mig-mixed.yaml`(MIG 전략), 앱 `../gitops/apps/05-kbl-ops-mig.yaml`

## 1. 전제 확인

- NVIDIA GPU Operator 가 설치되어 있고 드라이버가 B300 MIG 를 지원한다
- **ClusterPolicy 를 어느 리포가 관리할지** 정한다. `mig.strategy: mixed` 와 `migManager.config.name: custom-mig-config` 를
  한 곳에서만 관리한다 ([README.md](README.md#clusterpolicy-소유권-주의)). 다른 리포가 관리하면 `00-clusterpolicy-mig-mixed.yaml` 을 지우고 그쪽에 넣는다
- 그 노드에 GPU 를 쓰는 사용자 파드가 없다 (있으면 재분할이 실패·대기한다)
  ```bash
  oc get pods -A -o wide --field-selector spec.nodeName=<노드> | grep -v -E 'nvidia-gpu-operator|openshift-'
  ```

## 2. 장비에서 프로파일·배치 확인 (적용 전 1회)

```bash
# driver 파드 이름
D=$(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -o name | head -1)

# 프로파일 이름·개수, 배치 가능 위치
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -lgip
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -lgipp
```

- 이름이 `1g.34gb`, `1g.67gb`, `2g.67gb` 가 아니면 `10`·`30`·`40` 의 이름을 실제 값으로 바꾼다
- 배치 기대값: `1g.34gb` 0–6, `1g.67gb` 0·2·4·6, `2g.67gb` 0·2·4 (A100/H100 과 같은 규칙으로 추정 — 위 출력으로 확인)

**만드는 순서 확인 (선택)**: GPU 0·1 구성은 만드는 순서에 따라 실패할 수 있다(`1g.67gb` 가 2번 자리를 먼저 차지하면 `1g.34gb` 4개가 안 들어감).
mig-manager(mig-parted)가 순서를 바꿔 다시 시도하는 것으로 알고 있지만 문서로 확인되지 않았으므로, 빈 GPU 하나에서 직접 만들어 본다.
GPU Operator 의 mig-manager 가 관리하는 노드라면 이 시험은 MIG 를 적용하기 전에, 시험 후 반드시 지운다.

```bash
G=0   # 시험할 GPU
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi -i $G -mig 1
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -i $G -cgi 2g.67gb,1g.67gb,1g.34gb,1g.34gb,1g.34gb,1g.34gb -C   # 실패하는 순서인지
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -i $G -lgi
# 정리
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -i $G -dci
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -i $G -dgi
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi -i $G -mig 0
```

## 3. Git 수정 (사이트 값)

| 파일 | 할 일 |
|---|---|
| `20-node-labels.yaml` | `metadata.name` 을 실제 노드 이름으로 (`oc get nodes`) |
| `10-mig-config.yaml` | 2단계에서 이름이 다르면 수정. 그 외에는 그대로 |
| `30-hardwareprofile-mig.yaml` | CPU·메모리 범위를 KB 기준으로 조정 (GPU 노드 taint 가 있으면 tolerations 추가) |
| `40-resourcequota-mig.yaml` | 다른 네임스페이스(예: OCR worker)도 MIG 를 쓰면 `kbl-models` 몫을 줄이고 그쪽 quota 추가 |
| `00-clusterpolicy-mig-mixed.yaml` | 1단계에서 정한 소유 리포에 맞게 유지 또는 삭제 |
| `../gitops/apps/05-kbl-ops-mig.yaml` | 주석 해제 (앱 `kbl-ops-mig`, **수동 Sync**) |

커밋·push 하면 `kbl-root` 가 앱 `kbl-ops-mig` 를 만든다 (아직 동기화하지 않음).

## 4. 적용 (수동 Sync)

1. Argo CD 에서 `kbl-ops-mig` 를 **Sync** 한다 (ConfigMap → ClusterPolicy → 노드 라벨 → HardwareProfile·quota)
2. mig-manager 가 노드 라벨(`nvidia.com/mig.config=kbl-dgx-b300-v1`)을 보고 GPU 를 나눈다. 완료까지 기다린다
   ```bash
   oc get node <노드> -L nvidia.com/mig.config,nvidia.com/mig.config.state -w     # pending → success
   oc logs -n nvidia-gpu-operator -l app=nvidia-mig-manager -f                    # 진행 로그
   ```
   GPU·펌웨어에 따라 MIG 모드 전환에 GPU 리셋이나 노드 재부팅이 필요할 수 있다

## 5. 검증

```bash
# 노드 리소스 (0단계 표와 같아야 한다)
oc get node <노드> -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep nvidia.com

# GPU 별 배치
oc exec -n nvidia-gpu-operator $D -c nvidia-driver-ctr -- nvidia-smi mig -lgi
```

| GPU | 기대 배치 (시작 위치) |
|---|---|
| 0, 1 | `2g.67gb`@0, `1g.34gb`@2·3·4·5, `1g.67gb`@6 |
| 2–5 | `2g.67gb`@0·2·4, `1g.67gb`@6 |

RHOAI 쪽: `oc get hardwareprofile -n redhat-ods-applications | grep mig`, `oc describe quota mig -n kbl-models`

## 6. 실패했을 때

- 증상: `nvidia.com/mig.config.state=failed`, 일부 MIG 리소스가 노드에 없음
- **노드에서 `nvidia-smi` 로 직접 고치지 않는다.** mig-manager 가 라벨의 구성으로 다시 맞추면서 덮어쓰거나 충돌하고, Git 에 기록도 남지 않는다
- 순서: mig-manager 로그 확인 → 원인이 배치·순서면 **Git 에서 구성을 바꾼다**
  - 대안: GPU 0·1 의 `1g.67gb`×1 을 `1g.34gb`×2 로 (순서 문제가 없어진다. OCR worker 는 `1g.34gb` 2개 또는 다른 GPU 로)
  - 구성을 고칠 때는 새 이름(`kbl-dgx-b300-v2`)으로 추가하고 노드 라벨을 바꾼다 (README 변경 절차)

## 7. 모델 연결 (Raw ISVC, AI팀)

ISVC 에 HardwareProfile annotation 과 MIG 리소스를 함께 쓴다. 모델·정밀도는 계획 기준 (27B 는 NVFP4).

| 워크로드 | HardwareProfile | `resources.limits` | 개수 (계획) |
|---|---|---|---|
| AI Agent (27B) | `mig-2g-67gb` | `nvidia.com/mig-2g.67gb: 1` | 9 |
| OCR VLM1 (27B) | `mig-2g-67gb` | `nvidia.com/mig-2g.67gb: 1` | 2 |
| RAG | `mig-1g-67gb` | `nvidia.com/mig-1g.67gb: 1` | 3 |
| OCR VLM2 (Qwen3-VL-8B) | `mig-1g-34gb` | `nvidia.com/mig-1g.34gb: 1` | 4 |
| Embedding / Reranker | `mig-1g-34gb` | `nvidia.com/mig-1g.34gb: 1` | GPU 0·1 각 1 조각 (아래 8번) |

```yaml
metadata:
  annotations:
    opendatahub.io/hardware-profile-name: mig-2g-67gb
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
spec:
  predictor:
    model:
      resources:
        limits:   {cpu: "8", memory: 48Gi, nvidia.com/mig-2g.67gb: "1"}
        requests: {cpu: "4", memory: 48Gi, nvidia.com/mig-2g.67gb: "1"}
```

- MIG 조각은 메모리가 격리되므로 vLLM `--gpu-memory-utilization` 은 기본값을 써도 된다
- GPU 6·7(통 GPU)은 기존 `nvidia.com/gpu` 와 `gpu-1x`/`gpu-2x` 프로파일

## 8. 보류: 한 조각을 여러 파드가 나눠 쓰기 (time-slicing)

계획의 OCR worker(`1g.67gb` 1개에 파드 4개)와 Embedding/Reranker(`1g.34gb` 1개에 여러 replica)는 time-slicing 이 필요하다.
GPU Operator 의 time-slicing 은 **노드 단위·리소스 이름 단위**라서, 단일 DGX 노드에서는 그 이름의 모든 조각이 함께 쪼개진다.
- `1g.67gb` 를 쪼개면 RAG(GPU 2–4) 조각도 쪼개져 RAG 파드가 OCR worker 와 섞일 수 있다
- `1g.34gb` 를 쪼개면 OCR VLM2 조각도 쪼개진다

결정 전까지 time-slicing 은 설정하지 않는다. 선택지:
1. 공유하는 워크로드가 쓰는 프로파일을 노드에서 그 워크로드만 쓰게 계획을 바꾼다 (예: RAG 를 `1g.34gb` 로 — NVFP4 27B 는 약 15GB)
2. 공유 대신 파드 1개가 조각을 통째로 쓰고 그 안에서 worker 여러 개를 돌린다 (OCR worker)
3. Embedding 과 Reranker 를 각자 전용 `1g.34gb` 에 둔다 (GPU 0·1 의 예비 조각 사용)

## 9. 롤백

`20-node-labels.yaml` 의 라벨을 `all-disabled` 로 바꾸고 커밋 → `kbl-ops-mig` 수동 Sync. 1단계처럼 GPU 를 쓰는 파드를 먼저 내린다.
MIG 리소스를 쓰는 모델은 Pending 이 되므로 모델 `resources` 를 `nvidia.com/gpu` 로 바꾸거나 정지한다.
