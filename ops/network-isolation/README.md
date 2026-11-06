# 반입 모델 네트워크 격리 (RHOAI KServe Standard + ModelCar)

검증을 마친 모델을 RHOAI 에 배포할 때 모델 파드가 다음만 할 수 있도록 제한합니다.

- 나가는 트래픽: 모델별로 허용한 다른 네임스페이스의 **특정 파드 + 포트** (예: `rag-system` 의 vector-db 6333)만.
  그 외 다른 네임스페이스, **같은 네임스페이스의 다른 모델**, **클러스터 밖 시스템**, Kubernetes API 는 접근 불가
- 들어오는 트래픽: `kbl.io/model-consumer=true` 라벨이 있는 네임스페이스(에이전트, Gateway)와 메트릭 수집만

`kbl-models` 에는 런타임 등급(ga/fast/upstream)과 출처(validated/community)가 다른 모델이 함께 있으므로
모델 간 통신도 막습니다. 매니페스트는 [`deploy/ops/kbl-models/`](../kbl-models/) 에 있습니다 (Ops팀 관리).

## 구성: 3단계 방어

| 계층 | 리소스 | 관리 주체 | 역할 |
|---|---|---|---|
| 1 | `AdminNetworkPolicy` (`20-adminnetworkpolicy.yaml`) | cluster-admin | 프로젝트 관리자가 수정/삭제할 수 없는 상위 정책. DNS 만 허용, 허용 대상은 NetworkPolicy 로 위임(`Pass`), **같은 네임스페이스를 포함한 나머지는 차단(`Deny`)** |
| 2 | `EgressFirewall` (`21-egressfirewall.yaml`) | cluster-admin | **클러스터 밖으로 나가는 트래픽 전부 차단** (`0.0.0.0/0`, `::/0`) |
| 3 | `NetworkPolicy` (`31-`, `32-`, `network/allow-<ns>-<대상>.yaml`) | Ops팀 | 모델 파드 egress 기본 차단 + DNS 허용 + 대상별로 **목록에 있는 모델만** 허용 |
| 3 | `NetworkPolicy` (`33-networkpolicy-ingress.yaml`) | Ops팀 | 모델 파드 ingress: 소비 네임스페이스, User Workload Monitoring, 같은 ns 의 모델이 아닌 파드만 8080 허용 |
| + | ServiceAccount, env | Ops팀 / 정책 | SA 토큰 미마운트(Kubernetes API 로 다른 ns 조회 차단), vLLM/HF 외부 호출 비활성화 |

NetworkPolicy 만으로도 동작하지만 프로젝트 관리자(RHOAI 프로젝트 admin)가 지울 수 있습니다.
AdminNetworkPolicy 와 EgressFirewall 은 cluster-admin 만 바꿀 수 있으므로, NetworkPolicy 가 지워져도
다른 네임스페이스와 외부는 계속 차단됩니다.

대상은 KServe 가 예측 파드에 붙이는 라벨 `serving.kserve.io/inferenceservice` 가 있는 파드뿐입니다
(EgressFirewall 은 네임스페이스 전체). 워크벤치 등을 함께 두지 말고 **모델 전용 네임스페이스**로 씁니다.

## 적용

```bash
# 0. 지원 여부 확인 (OVN-Kubernetes 필요)
oc api-resources | grep -E 'adminnetworkpolicies|egressfirewalls'

# 1. 정책 (InferenceService 보다 먼저) — ../README.md 의 순서 참고
oc apply -R -f deploy/ops/kbl-models/
```

> 정책을 먼저 적용하고 InferenceService 를 배포하면, 모델이 뜨는 순간부터 격리된 상태가 됩니다.

### 허용 대상 추가

허용 대상(다른 네임스페이스의 파드 + 포트) 하나당 파일 하나, ANP 규칙 하나가 짝입니다.

| 파일 | 내용 |
|---|---|
| `network/allow-<ns>-<대상>.yaml` | 대상 endpoint + 접근할 수 있는 모델 목록 (`serving.kserve.io/inferenceservice In [...]`) |
| `20-adminnetworkpolicy.yaml` | `pass-<ns>-<대상>` 규칙 (`deny-other-namespaces` **앞에**) |

- **기존 대상에 모델 추가**: NetworkPolicy 의 `values` 에 모델 이름 한 줄 추가. ANP 는 그대로
- **새 대상**: 두 파일을 같은 커밋으로 추가. ANP 에만 추가하면 NetworkPolicy 에서 막히고,
  NetworkPolicy 에만 추가하면 ANP 에서 막힙니다
- 모델 목록은 Ops팀 폴더에서 관리합니다. ISVC 라벨로 opt-in 하게 하면 AI팀이 스스로 네트워크를 열 수 있습니다

## 주의사항

- **포트는 서비스 포트가 아니라 파드의 컨테이너 포트(targetPort)** 입니다. NetworkPolicy 는 서비스 주소 변환(DNAT) 이후에
  평가되므로, 대상도 서비스가 아니라 **파드 라벨**로 지정합니다. DNS 도 같은 이유로 53 이 아니라 5353 입니다.
- **ModelCar** 는 노드(kubelet)가 이미지를 받으므로 파드 egress 와 무관합니다. S3/URI 방식으로 바꾸면
  storage-initializer 가 파드 안에서 다운로드하므로 해당 저장소를 허용해야 합니다.
- **들어오는 트래픽은 `33-networkpolicy-ingress.yaml` 로 제한합니다.** 소비 네임스페이스 라벨은 Ops팀이 붙입니다.
  NetworkPolicy 는 상태를 추적하므로 허용된 요청에 대한 응답은 egress 차단과 관계없이 나갑니다.
  ingress 는 ANP 로 막지 않았으므로 프로젝트 관리자가 NetworkPolicy 를 지우면 열립니다 (Argo CD selfHeal 로 복구).
- **토큰 인증(Require token authentication)과 충돌합니다.** InferenceService 에 토큰 인증을 켜면 RHOAI 가 예측 파드에
  인증 프록시 사이드카(kube-rbac-proxy / oauth-proxy)를 추가하는데, 이 사이드카는 **파드의 SA 토큰으로 API 서버를 호출**합니다.
  이 구성(토큰 미마운트 + API 서버 차단)에서는 인증이 실패합니다. 선택지:
  1. 인증은 앞단(API Gateway, Gateway API + Authorino 등)에서 처리하고 예측 파드는 그대로 격리 (권장)
  2. 사이드카 인증을 쓴다면 SA 토큰 마운트를 허용하고, API 서버(노드 IP:6443)를 EgressFirewall `Allow`
     와 NetworkPolicy `ipBlock` 으로 열어야 합니다. 같은 파드의 모델 컨테이너도 API 서버에 닿게 되므로
     SA 의 RBAC 권한을 최소로 유지하세요.
- EgressFirewall 은 네임스페이스당 하나(`default`)만 가능합니다. 이미 있으면 합쳐야 합니다.
- AdminNetworkPolicy `priority` 는 OVN-Kubernetes 에서 0~99 (낮을수록 우선)이며 같은 우선순위끼리 겹치면 안 됩니다.
  소비 주체별로 네임스페이스를 더 만들면 다른 값(예: 51, 52, ...)을 쓰세요.
- vLLM/HF 오프라인 env (`HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE`, `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK`)는
  네트워크가 막혀 있어도 시도 자체를 없애 타임아웃 지연과 불필요한 로그를 줄입니다.

## 검증 (클러스터)

```bash
./verify.sh kbl-models qwen3-4b-instruct \
  vector-db.rag-system.svc:6333:allow \
  <다른 모델>-predictor.kbl-models.svc:8080:deny \
  vector-db.rag-system.svc:9999:deny \
  some-svc.other-namespace.svc:8080:deny \
  huggingface.co:443:deny \
  10.0.0.10:443:deny            # 사내 다른 시스템 IP
```

추가로 확인할 것:

1. NetworkPolicy 를 지워도 (`oc delete networkpolicy -n kbl-models --all`) 다른 ns / 외부 / 다른 모델이 계속 `deny` 인지
   (AdminNetworkPolicy + EgressFirewall 동작 확인) → 확인 후 Argo CD `kbl-ops-kbl-models` 동기화(selfHeal)로 복구되는지 확인
2. 추론이 정상인지: `oc get inferenceservice -n kbl-models`, `/v1/models` 호출 ([../README.md](../README.md#점검))
3. 정책 상태: `oc get adminnetworkpolicy model-isolation-kbl-models -o yaml` 의 `status.conditions`,
   `oc get egressfirewall -n kbl-models` 의 `EgressFirewall Rules applied`
