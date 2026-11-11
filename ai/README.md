# AI팀: InferenceService

> 현재 생성형 모델은 `maas/`(llm-d + MaaS, 아래 절)로 배포합니다. `raw/` 의 InferenceService 는 보관본이며
> Argo CD 앱(`ops/gitops/apps/22-kbl-ai-raw.yaml`)이 주석 처리되어 동기화되지 않습니다.

`raw/` 의 파일 하나가 모델 하나(InferenceService)입니다. 앱을 켜면 Argo CD(`kbl-ai-raw`)가 동기화하고,
파일을 지우면 모델도 내려갑니다. 이 폴더에는 **InferenceService 만** 둘 수 있습니다 (다른 리소스는 Argo CD 가 거부).

런타임(ServingRuntime), 네임스페이스, 네트워크, quota 는 Ops팀이 관리합니다 ([../ops/README.md](../ops/README.md)).

## 규칙

아래 규칙은 리뷰(PR)에서 확인합니다.

**등급과 출처** — 세 값을 항상 함께 맞춥니다

| 라벨 | 함께 맞출 값 |
|---|---|
| `kbl.io/runtime-tier: ga\|fast\|upstream` | `spec.predictor.model.runtime: vllm-<등급>-<버전>` |
| `kbl.io/model-source: validated\|community` | `storageUri: oci://nexus.internal.example:5000/models-<출처>/...@sha256:<digest>` |

**바꿀 수 있는 것**: 이름, display-name, `storageUri`(허용된 repo 의 digest), 등급/출처(위 표대로), `args`, `env`,
`resources`(고른 HardwareProfile 과 네임스페이스 GPU quota 범위), replica 수

**probe**: startup/readiness/liveness 는 런타임(ServingRuntime) 기본값을 쓴다. 로딩이 10분을 넘는 큰 모델만
`spec.predictor.model.startupProbe` 의 `failureThreshold` 를 늘린다 (liveness 를 끄거나 줄이지 않는다)

**쓰지 않는 것**

| 필드 | 이유 |
|---|---|
| `spec.predictor.model.image`, `model.command` | 이미지와 실행 명령은 ServingRuntime 이 정함 |
| `spec.predictor.containers`, `initContainers`, `spec.transformer`, `spec.explainer` | 승인되지 않은 이미지 실행 경로 |
| `serviceAccountName` 을 `model-serving` 이외로 | 파드 권한·pull secret 은 Ops 가 정한 SA 로만 |
| `automountServiceAccountToken: true` (토큰 인증을 켜지 않았는데) | API 토큰 노출. 토큰 인증(`enable-auth: "true"`)일 때만 `true` |
| 라벨 `networking.kserve.io/visibility: exposed` | 외부 Route. 외부 노출은 Gateway 로 |
| (참고) `security.opendatahub.io/enable-auth: "true"` | 사용 가능. 호출 권한은 Ops 에 요청(`ops/kbl-models/50-model-callers.yaml`), 호출자 ns 에 `kbl.io/model-consumer=true` 필요 |
| 태그로 지정한 `storageUri` | digest 만 허용 (검사한 이미지와 정확히 일치시키기 위해) |

## 모델 추가

```bash
# 1. 반입 검사를 통과한 모델을 이미지로 빌드/push (커뮤니티 모델은 models-community)
uv run hf-modelcar models/<name> \
  --image nexus.internal.example:5000/models-community/<owner>/<model>:<commit 12자> --push
#    출력되는 oci://...@sha256:... 를 storageUri 에 쓴다

# 2. 예시를 복사해 수정
#    qwen3-4b-instruct.yaml: 검증 모델, GA 런타임, GPU 1장
#    gemma-4-26b.yaml:       커뮤니티 모델, upstream 런타임, GPU 2장 (--tensor-parallel-size=2, gpu-2x)
#    metadata.name / display-name, 라벨, runtime, storageUri, args(--max-model-len 등), resources

# 3. 커밋 전 스키마 확인 (권한이 있으면)
oc apply --dry-run=server -f deploy/ai/raw/<모델>.yaml

# 4. 카탈로그 갱신 (같은 커밋에 포함)
uv run python scripts/model-catalog.py
```

- 쓸 수 있는 런타임: `oc get servingruntime -n kbl-models -L kbl.io/runtime-tier`
- 쓸 수 있는 HardwareProfile: `oc get hardwareprofiles -n redhat-ods-applications`
  (ISVC annotation `opendatahub.io/hardware-profile-name`, resources 는 프로파일 범위 안, GPU 2장 이상이면 `--tensor-parallel-size`)
- 필요한 vLLM 버전이 없으면 Ops팀에 런타임 추가를 요청합니다
- 다른 네임스페이스(예: vector DB) 접근이 필요하면 Ops팀에 요청합니다. 기본은 DNS 외 모든 egress 차단이고,
  다른 모델과도 통신할 수 없습니다
- `models-validated` 로의 승격은 승인자가 이미지를 복사한 뒤 `kbl.io/model-source` 와 `storageUri` 를 바꿉니다 (digest 동일)

## 에이전트용 설정

모델 카탈로그([CATALOG.md](CATALOG.md))가 에이전트 개발자에게 공개되는 모델 목록입니다. ISVC 파일에서 생성합니다.

- `openshift.io/description`: 카탈로그에 표시할 용도 설명
- tool calling: 에이전트가 OpenAI API 의 `tools` 를 쓰려면 `args` 에 `--enable-auto-tool-choice` 와
  `--tool-call-parser=<파서>` 가 필요합니다. 파서는 모델 계열마다 다르므로 vLLM 문서에서 확인합니다 (예: Qwen3 → `hermes`)
- `--max-model-len`: 카탈로그의 최대 컨텍스트로 표시됩니다. 에이전트는 이 길이를 넘는 요청을 보내면 안 됩니다
- 모델 이름(`model`)은 ISVC 이름입니다. 등급을 바꿔도 이름과 엔드포인트는 그대로이므로 에이전트 설정은 바뀌지 않습니다

## 등급 변경 (예: fast → ga)

`kbl.io/runtime-tier` 와 `runtime` 을 한 커밋에서 함께 바꿉니다. 파드는 새 런타임으로 다시 뜨고
엔드포인트(`<모델>-predictor.kbl-models.svc`)는 그대로입니다.

## 확인

```bash
oc get isvc -n kbl-models
oc get events -n kbl-models --sort-by=.lastTimestamp | tail -20
oc logs -n kbl-models deploy/<모델>-predictor -c kserve-container | tail
oc port-forward -n kbl-models deploy/<모델>-predictor 8080:8080 &   # 로컬에서 호출
curl -s localhost:8080/v1/models
```

| 증상 | 확인할 것 |
|---|---|
| Argo CD `resource ... is not permitted in project` | 이 폴더에 InferenceService 가 아닌 리소스가 있음 |
| 파드 `Pending` | 네임스페이스 GPU quota(`oc describe quota -n kbl-models`), GPU 노드 여유 |
| `ImagePullBackOff` | storageUri digest 가 Nexus 에 있는지 |
| vLLM 기동 중 OOM / KV cache 부족 | `--max-model-len` 축소, `--gpu-memory-utilization` 조정 |

## llm-d + MaaS 모델 (`maas/`)

`maas/` 의 파일 하나가 LLMInferenceService 하나입니다 (네임스페이스 `kbl-maas`, Argo CD 앱 `kbl-ai-maas`).
MaaS 게시(MaaSModelRef)와 누가·얼마나 쓸 수 있는지(MaaSAuthPolicy·MaaSSubscription)는 Ops팀이 관리합니다.

| 바꿀 수 있는 것 | 바꾸지 않는 것 (Ops팀 요청) |
|---|---|
| `model.uri`(digest), `model.name`, `replicas`, `resources`, env `VLLM_ADDITIONAL_ARGS` | `baseRefs`(vLLM 런타임), `router.gateway`(MaaS gateway), `image`, `security.opendatahub.io/enable-auth` |

```bash
oc get llmisvc -n kbl-maas
oc get pods -n kbl-maas
oc logs -n kbl-maas deploy/<모델>-kserve -c main | grep 'vllm version'   # vLLM 버전
```
호출은 MaaS API 키로 합니다: `https://maas.<apps 도메인>/v1/chat/completions` (body 의 `model` = `model.name`).
