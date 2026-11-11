# RHOAI 3.5 배포 (KServe Standard + ModelCar)

`hf-modelcar` 로 만든 ModelCar 이미지를 RHOAI 3.5 에서 KServe Standard(RawDeployment) 모드로 서빙합니다.
OpenShift GitOps(Argo CD)로 배포하고, Ops팀과 AI팀이 폴더를 나눠 관리합니다.
나중에 리포를 나눌 때는 `ops/`, `ai/` 을 각각 리포로 옮기고 Argo CD 의 `repoURL`/`path` 만 바꿉니다.

| 폴더 | 담당 | 내용 | 문서 |
|---|---|---|---|
| [`ops/`](ops/) | Ops팀 | 플랫폼 설정, 모델 네임스페이스, 네트워크 격리, RBAC, vLLM 런타임, Argo CD 설정 | [ops/README.md](ops/README.md) |
| [`ai/`](ai/) | AI팀 | InferenceService | [ai/README.md](ai/README.md) |

## 등급과 출처

모델은 네임스페이스 하나(`kbl-models`)에 두고, 등급과 출처는 **라벨과 Nexus repo** 로 구분합니다.
등급을 바꿔도 네임스페이스가 그대로라 엔드포인트(`<모델>-predictor.kbl-models.svc`)가 바뀌지 않습니다.
네임스페이스를 나눈다면 등급이 아니라 소비 주체·업무 기준으로 나눕니다.

| 구분 | 표시 | 실제 근거 | 함께 맞출 값 |
|---|---|---|---|
| 런타임 등급 | ServingRuntime·ISVC 라벨 `kbl.io/runtime-tier: ga\|fast\|upstream` | Nexus `vllm-ga` / `vllm-fast` / `vllm-upstream` repo (push 권한) | 이미지 repo, 런타임 이름 `vllm-<등급>-<버전>`, `kbl.io/support-status` |
| 모델 출처 | ISVC 라벨 `kbl.io/model-source: validated\|community` | Nexus `models-validated` / `models-community` repo (push 권한) | `storageUri` repo |

- 라벨은 누구나 붙일 수 있으므로 "GA = 승인된 이미지" 는 **Nexus repo 의 push 권한**으로 보장합니다.
  라벨과 실제 이미지/모델 경로가 맞는지는 리뷰(PR)에서 확인합니다
- 이미지와 모델은 모두 digest(`@sha256:`)로만 참조합니다 (태그는 바뀔 수 있음)
- Model Registry 는 하나만 두고 custom property(출처, 검증 상태, 런타임 등급)로 구분합니다.
  출처·라이선스 값은 `MODEL_INFO.json` 에서 가져옵니다

## 역할 분리

| | Ops팀 | AI팀 |
|---|---|---|
| Git | `ops/` | `ai/` |
| Argo CD | AppProject `kbl-ops` (클러스터 전체, MaaS 정책 포함) | AppProject `kbl-ai` (kbl-maas 의 LLMInferenceService, kbl-models 의 InferenceService 만) |
| 클러스터 권한 | kbl-models admin + 격리 정책 조회 (변경은 Git→Argo CD) | Role `kbl-ai-developer`: kbl-models 조회 전용 (ISVC 변경은 Git→Argo CD) |
| RHOAI 대시보드 | Auth `adminGroups` (kbl-ops-admins) | Auth `allowedGroups` (kbl-ai-developers) |
| 사용자 | Group 멤버십 `ops/platform/groups.yaml` | |
| Nexus | `vllm-*` push, `models-validated` push(승인자) | `models-community` push |
| 요청 | ← 런타임 추가, 다른 네임스페이스 접근, GPU quota | |
| 에이전트 팀 | 소비 네임스페이스 라벨(`kbl.io/model-consumer=true`) 부여 | [모델 카탈로그](ai/CATALOG.md) 관리 |

AI팀이 ISVC 를 직접 수정하므로, ISVC 에서 쓰지 않을 필드(`model.image`, 커스텀 컨테이너, SA 변경, 외부 Route 등)는
리뷰에서 확인합니다. 목록은 [ai/README.md](ai/README.md#규칙) 에 있습니다.

## 에이전트 개발

에이전트 개발자는 [모델 카탈로그](ai/CATALOG.md)에서 모델 이름과 OpenAI 호환 엔드포인트를 확인합니다.
카탈로그는 AI팀 ISVC 파일에서 `scripts/model-catalog.py` 로 생성하므로 실제 배포와 같습니다.
호출하려면 에이전트 네임스페이스에 Ops팀이 `kbl.io/model-consumer=true` 라벨을 붙여야 합니다.

```python
from openai import OpenAI
# ISVC 는 토큰 인증 필수: 호출 SA 의 토큰을 api_key 로 (Ops 가 ops/kbl-models/50-model-callers.yaml 에 등록)
# 자체 서명 인증서(service CA)이므로 http_client=httpx.Client(verify="/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt")
client = OpenAI(base_url="https://qwen3-4b-instruct-predictor.kbl-models.svc:8443/v1", api_key=open("/var/run/secrets/kubernetes.io/serviceaccount/token").read())
client.chat.completions.create(model="qwen3-4b-instruct", messages=[...], tools=[...])
```

## 다음 단계

- **리포 분리**: `ops/`, `ai/` 을 각 리포로 옮기고 `ops/gitops/` 의 `sourceRepos`, `repoURL`, `path` 변경
- **Gateway / MaaS**: 앞단에서 모델 이름 기준으로 라우팅하면 뒤쪽 배치(네임스페이스, 등급)가 바뀌어도
  호출하는 에이전트는 영향을 받지 않습니다. 인증도 이 앞단에서 처리합니다
- **이미지 서명**: Nexus `vllm-ga` / `models-validated` 이미지에 cosign 서명 + `ClusterImagePolicy`

> RHOAI 3.5 필드(DSC `v2`, HardwareProfile `infrastructure.opendatahub.io/v1`, `deploymentMode: Standard`)는
> 3.5 대상 공개 예시를 기준으로 했습니다. 처음 적용할 때 `oc apply --dry-run=server` 로 스키마를 확인하세요.
