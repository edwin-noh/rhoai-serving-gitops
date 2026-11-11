# 서빙 리소스의 라벨·annotation 출처와 용도

`deploy/` 의 ServingRuntime / InferenceService / LLMInferenceService / LLMInferenceServiceConfig / MaaSModelRef / Namespace 에
붙인 라벨과 annotation 이 **어디에 근거하고, 누가 읽고, 없으면 무엇이 달라지는지** 정리한다.
기준: RHOAI Self-Managed 3.5 문서(PDF 38종 전체 검색), 클러스터 rhoai-35(3.5.2) 관찰 (2026-11-11).

## 근거 등급

| 표시 | 의미 |
|---|---|
| **문서** | RHOAI 3.5 공식 문서에 키와 의미가 나온다 (문서명 · 절) |
| **문서(예시)** | 3.5 문서 YAML 예시에 나오지만 의미 설명은 없다 |
| **관찰** | 3.5 문서에는 없다(**3.5 미확인**). 클러스터의 RHOAI 기본 템플릿이나 대시보드가 만든 리소스에 붙어 있어 플랫폼이 쓰는 것으로 판단 |
| **업스트림** | KServe / Kubernetes / Prometheus 관례. 3.5 문서 근거는 별도 표기 |
| **자체** | 우리가 정한 관례. 어떤 컨트롤러도 읽지 않는다 (리뷰·조회·카탈로그 생성용) |

> CRD 스키마(`oc explain`)는 metadata 의 라벨/annotation 키를 정의하지 않는다. 그래서 "API 에 있다" 는 근거는
> 문서 또는 컨트롤러 동작(관찰)뿐이다.

---

## 1. ServingRuntime (`ops/kbl-models/runtimes/*.yaml`)

| 키 | 종류 | 값 | 근거 | 누가 쓰나 / 효과 |
|---|---|---|---|---|
| `opendatahub.io/dashboard` | label | `"true"` | **문서(예시)** Configuring your model-serving platform §1.2.1 ServingRuntime, §2.4 | 대시보드가 RHOAI 리소스로 인식해 목록에 표시 |
| `openshift.io/display-name` | annotation | `vLLM 0.24.0 (RHAIIS 3.5.2, GA)` | **문서** 같은 §1.2.1 "The name with which the serving runtime is displayed." / §2.4 "없으면 metadata.name 표시" | 대시보드 표시 이름 |
| `opendatahub.io/recommended-accelerators` | annotation | `'["nvidia.com/gpu"]'` | **문서** §1.2.1 "The recommended accelerator to use with the runtime." / Working with accelerators §7.3.2 | 대시보드가 HW profile 의 accelerator 와 맞춰 런타임을 추천 |
| `opendatahub.io/support-status` | annotation | `unsupported` | **문서** §1.4 Limited-support runtime visibility and gating, §2.6, §2.7 | 제한 지원 런타임을 숨기고 관리자 수락 전까지 배포 불가. 없으면 supported 로 취급 (§2.7) |
| `opendatahub.io/unsupported-status-accepted` | annotation | `"true"` | **문서** §1.4 (GitOps workflow) | 위 런타임을 관리자가 수락 → 표시됨. 대시보드에서 수락하면 이 annotation 이 자동으로 붙는다 |
| `opendatahub.io/runtime-version` | annotation | `v0.24.0` | **관찰** RHOAI 기본 템플릿 `vllm-cuda-runtime-template` 의 런타임에 같은 키(`v0.24.0`)가 있음 | 런타임 버전 표기. 대시보드 버전 배지(Deploying models §2.3 "Version badge")의 출처인지는 3.5 미확인. 우리는 버전 조회(`oc get servingruntime -o custom-columns`)에 사용 |
| `opendatahub.io/apiProtocol` | annotation | `REST` | **관찰** 기본 템플릿 metadata 에 `REST` | 대시보드가 엔드포인트 프로토콜(REST/gRPC) 표시·배포 폼에 사용하는 것으로 판단 |
| `opendatahub.io/template-name` | annotation | `vllm-cuda-runtime-template` | **문서(예시)** Enabling AI safety with guardrails §4.3 / **관찰** 대시보드가 만든 런타임에 붙음 | 어떤 템플릿에서 나온 런타임인지. 대시보드가 템플릿과 연결할 때 사용 |
| `opendatahub.io/template-display-name` | annotation | `vLLM NVIDIA GPU ServingRuntime for KServe` | **관찰** 대시보드가 만든 런타임에 붙음 | 템플릿 표시 이름 |
| `spec.annotations.prometheus.io/path`, `prometheus.io/port` | (spec 의 annotation) | `/metrics`, `"8080"` | **문서** §1.2.1 "The endpoint/port used by Prometheus to scrape metrics" | 예측 파드에 전달되어 메트릭 수집 대상이 됨 |
| `kbl.io/runtime-tier` | label | `ga` / `fast` / `upstream` | **자체** | 등급 표시. `oc get servingruntime -L kbl.io/runtime-tier`, PR 리뷰 |
| `kbl.io/support-status` | annotation | `supported` / `unsupported` | **자체** — ⚠ 공식 `opendatahub.io/support-status` 와 중복 (아래 권고) | 지금은 표시용일 뿐 대시보드 노출을 막지 않는다 |

## 2. InferenceService (`ai/raw/qwen3-4b-instruct.yaml`)

| 키 | 종류 | 값 | 근거 | 누가 쓰나 / 효과 |
|---|---|---|---|---|
| `opendatahub.io/dashboard` | label | `"true"` | **문서(예시)** Configuring §1.2.2 InferenceService | 대시보드 Deployments 목록 표시 |
| `openshift.io/display-name` | annotation | `Qwen3-4B-Instruct-2507` | **문서(예시)** §1.2.2 | 대시보드 표시 이름 |
| `openshift.io/description` | annotation | 용도 설명 | **업스트림**(OpenShift 공통 annotation). 3.5 문서는 workbench 예시에만(Creating a workbench) | 대시보드 설명란. 우리 `scripts/model-catalog.py` 가 카탈로그 용도 칸으로 읽는다 |
| `serving.kserve.io/deploymentMode` | annotation | `Standard` | **문서** Deploying models §2.6 canary 예시는 `RawDeployment` / **관찰** 3.5.2 대시보드가 만든 ISVC 는 `Standard` | KServe 배포 방식. Standard(=RawDeployment 의 새 이름, Knative 없이 Deployment) — 3.x 는 이 방식만 씀 |
| `opendatahub.io/hardware-profile-name` | annotation | `nvidia-gpu-serving` | **관찰** 대시보드가 만든 ISVC 에 있음. PoC 에서 이 annotation 으로 프로파일의 tolerations 가 ISVC 에 자동 주입됨 | ODH webhook 이 HW profile 의 scheduling(tolerations/nodeSelector)·기본 resources 적용. 3.5 Migration 문서는 "hardware-profile annotations" 존재만 언급 |
| `opendatahub.io/hardware-profile-namespace` | annotation | `redhat-ods-applications` | **관찰** (위와 같음) | 프로파일이 있는 네임스페이스 |
| `opendatahub.io/model-type` | annotation | `generative` | **관찰** 대시보드가 만든 ISVC, 템플릿 metadata(`["generative"]`) | 대시보드의 생성형/예측형 구분(Gen AI 기능 노출 등) |
| `security.opendatahub.io/enable-auth` | annotation | `"false"` | **문서**는 LLMInferenceService(llm-d 5장)·Guardrails 용. ISVC 는 대시보드 "Require token authentication" 체크박스로만 설명(Deploying models §2.9) / **관찰** 대시보드가 ISVC 에 이 키를 씀 | `true` 면 인증 프록시 사이드카. 네트워크 격리(SA 토큰 미마운트)와 충돌해 우리는 `false` |
| `kbl.io/runtime-tier`, `kbl.io/model-source` | label | `ga`, `validated` | **자체** | 등급·출처 표시, 카탈로그, PR 리뷰 (`storageUri` repo 와 맞는지) |

대시보드가 ISVC 에 쓰지만 우리가 **일부러 쓰지 않는 것** (관찰, model-hub 의 대시보드 배포 기준):

| 키 | 효과 | 쓰지 않는 이유 |
|---|---|---|
| label `networking.kserve.io/visibility: exposed` | 외부 Route 생성 (**업스트림** KServe, 3.5 문서에 없음) | 외부 노출은 Gateway/MaaS 로만 |
| label `opendatahub.io/genai-asset: "true"` | Gen AI studio 의 AI asset endpoint 로 표시 ("Add as AI asset endpoint") | 필요 시 추가 |
| label `monitoring.opendatahub.io/scrape: "true"` | 대시보드 메트릭 수집 | 필요 시 추가 (UWM 설정 확인) |
| annotation `serving.kserve.io/stop` | 모델 정지 (대시보드 Stop). 3.5 문서는 llm-d §6.4 에서만 | Git 으로 `"true"` 를 커밋하면 정지 가능 |
| annotation `opendatahub.io/connections` | 연결(Secret) 지정 — **문서** Working on projects §3.4 | ModelCar 이미지는 노드가 받으므로 불필요 |
| annotation `opendatahub.io/hardware-profile-resource-version` | webhook 이 넣는 프로파일 버전 | 사람이 쓰지 않음 |
| label `modelregistry.opendatahub.io/*` | Model Registry 연결 | 레지스트리 연동 시 |

## 3. LLMInferenceService (`ai/maas/qwen3-4b-instruct.yaml`)

| 키 | 종류 | 값 | 근거 | 누가 쓰나 / 효과 |
|---|---|---|---|---|
| `opendatahub.io/dashboard` | label | `"true"` | **문서(예시)** (llm-d 19.1.1 은 토큰용 Role/Secret 에) / ISVC 와 같은 관례 | 대시보드 표시 |
| `openshift.io/display-name`, `openshift.io/description` | annotation | | ISVC 와 같음 | 대시보드 표시 |
| `security.opendatahub.io/enable-auth` | annotation | **미지정** | **문서** llm-d 5장 "Authentication is enabled by default. Only an explicit `"false"` disables" | MaaS 모델은 인증 필수 → 쓰지 않거나 `"true"`. `"false"` 금지 |
| `kbl.io/runtime-tier`, `kbl.io/model-source` | label | | **자체** | |

참고 (우리는 쓰지 않음, 문서에 있는 것):
- `serving.kserve.io/stop` — 정지 (llm-d §6.4)
- `opendatahub.io/model-capabilities: '["vision"]'` — Playground 에서 이미지 입력 허용 (Experimenting with models in the gen AI playground)
- `spec.annotations.serving.kserve.io/model-based-routing-enabled` — 플랫폼 기본 템플릿이 설정 (관찰)

## 4. LLMInferenceServiceConfig (`ops/kbl-maas/runtimes/vllm-ga-3-5-2.yaml`)

| 키 | 종류 | 근거 | 효과 |
|---|---|---|---|
| `opendatahub.io/runtime-version` | annotation | **관찰**(ServingRuntime 관례를 따름). 기본 llm-d config 에는 없음 | 우리 버전 조회용. llm-d 의 실제 버전은 vLLM 로그 `[access-log-detect] vllm version=` (llm-d §8.2) |
| `openshift.io/display-name` | annotation | ServingRuntime 과 같은 관례 | 대시보드(LLM accelerator configurations) 표시 — 3.5 미확인 |
| `opendatahub.io/support-status`, `unsupported-status-accepted`, `opendatahub.io/fast-version` | annotation | **문서** Configuring §1.4, §2.6 (LLMInferenceServiceConfig 에도 적용) | 제한 지원 config 노출 제어. 우리 GA config 에는 불필요 |
| `opendatahub.io/config-type` | label | **문서** llm-d §2.8 (`workload-single-node`, `router` …) | 대시보드 topology/router 분류. 우리 config 에는 없음 — 대시보드 선택지에 노출하려면 추가 검토 |
| `serving.kserve.io/well-known-config` | annotation | **관찰** 플랫폼 기본 config 에만 | 플랫폼 기본 config 표시. 우리는 쓰지 않음 |
| `kbl.io/runtime-tier` | label | **자체** | |

## 5. MaaSModelRef / Namespace / Argo CD

| 리소스 | 키 | 근거 | 효과 |
|---|---|---|---|
| Namespace | label `opendatahub.io/dashboard: "true"` | **문서** Creating a workbench "label the namespace so that the project appears under the default filter" / Working on projects | 대시보드 Projects 에 표시 |
| Namespace (`kbl-maas`) | label `maas.opendatahub.io/gateway-access: "true"` | **관찰** `maas-default-gateway` listener 의 `allowedRoutes` selector. 문서는 테넌트용 `maas.opendatahub.io/gateway-access-${TENANT_NAME}` 만 (Govern…MaaS §1.20.3) | 없으면 HTTPRoute 가 gateway 에 붙지 않음 |
| Namespace | label `argocd.argoproj.io/managed-by: openshift-gitops` | **업스트림** OpenShift GitOps | Argo CD 기본 인스턴스가 이 네임스페이스를 관리할 권한 |
| 여러 리소스 | annotation `argocd.argoproj.io/sync-wave` | **업스트림** Argo CD | 같은 앱 안의 적용 순서 |
| MaaSModelRef | annotation `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` | **업스트림** Argo CD | 참조 대상이 아직 없어도 동기화 진행 |
| ClusterPolicy / Node (mig) | annotation `argocd.argoproj.io/sync-options: Delete=false,Prune=false` | **업스트림** Argo CD | Argo 가 지우지 않음 |

---

## 권고 (이번 정리에서 나온 것)

1. **upstream 런타임**(`vllm-upstream-0-28-0.yaml`): `kbl.io/support-status: unsupported` 대신(또는 함께) 공식
   `opendatahub.io/support-status: unsupported` + `opendatahub.io/unsupported-status-accepted: "true"` 를 쓴다.
   그래야 대시보드에서 제한 지원 런타임으로 표시되고, 수락 없이 쓰이지 않는다 (Configuring §1.4). GA 런타임은 둘 다 생략(=supported).
2. `kbl.io/*` 는 컨트롤러가 읽지 않는다. 등급 보장은 Nexus push 권한과 PR 리뷰로 한다 (deploy/README.md).
3. **관찰** 등급 키(`hardware-profile-*`, `model-type`, `apiProtocol`, `runtime-version`, `template-*`, `gateway-access`)는
   문서가 보장하지 않는다. RHOAI 업그레이드 때 대시보드로 모델을 하나 만들어 붙는 키를 다시 비교한다:
   ```bash
   oc get isvc,llmisvc,servingruntime -n <대시보드로 만든 프로젝트> -o yaml | grep -E '^\s+(opendatahub|security|serving|networking|maas)\.'
   ```
4. `serving.kserve.io/deploymentMode` 는 문서 예시(`RawDeployment`)와 3.5.2 대시보드(`Standard`)가 다르다. 둘 다 Knative 없는
   배포를 뜻하며, 우리는 대시보드와 같은 `Standard` 를 유지한다.
