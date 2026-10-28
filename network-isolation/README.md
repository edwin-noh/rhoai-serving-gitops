# 반입 모델 네트워크 격리 (RHOAI KServe Standard + ModelCar)

검증을 마친 모델을 RHOAI 에 배포할 때 모델 파드가 다음만 할 수 있도록 제한합니다.

- 배포된 네임스페이스 안의 통신
- 허용한 다른 네임스페이스의 **특정 파드 + 포트** (예: `rag-system` 의 vector-db 6333)
- 그 외 다른 네임스페이스, **클러스터 밖 시스템**, Kubernetes API 는 접근 불가

## 구성: 3단계 방어

| 계층 | 리소스 | 관리 주체 | 역할 |
|---|---|---|---|
| 1 | `AdminNetworkPolicy` | cluster-admin | 프로젝트 관리자가 수정/삭제할 수 없는 상위 정책. DNS 만 허용, 같은 ns 와 허용 대상은 NetworkPolicy 로 위임(`Pass`), **나머지 네임스페이스는 차단(`Deny`)** |
| 2 | `EgressFirewall` | cluster-admin | **클러스터 밖으로 나가는 트래픽 전부 차단** (`0.0.0.0/0`, `::/0`) |
| 3 | `NetworkPolicy` | 프로젝트 | 모델 파드 egress 기본 차단 + DNS / 같은 ns / 허용 대상만 허용 |
| + | ServiceAccount, env | 프로젝트 | SA 토큰 미마운트(Kubernetes API 로 다른 ns 조회 차단), vLLM/HF 외부 호출 비활성화 |

NetworkPolicy 만으로도 동작하지만 프로젝트 관리자(RHOAI 프로젝트 admin)가 지울 수 있습니다.
AdminNetworkPolicy 와 EgressFirewall 은 cluster-admin 만 바꿀 수 있으므로, NetworkPolicy 가 지워져도
다른 네임스페이스와 외부는 계속 차단됩니다.

대상은 KServe 가 예측 파드에 붙이는 라벨 `serving.kserve.io/inferenceservice` 가 있는 파드뿐입니다
(EgressFirewall 은 네임스페이스 전체). 같은 프로젝트의 워크벤치 등을 함께 두지 말고 **모델 전용 네임스페이스**를 권장합니다.

## 디렉터리

```
cluster/        AdminNetworkPolicy, EgressFirewall (cluster-admin)
namespace/      NetworkPolicy 4개, ServiceAccount (모델 네임스페이스)
overlays/example/
  cluster/      값 패치: 모델 ns=kblife-models, 허용 대상=rag-system/app=vector-db:6333
  namespaced/   namespace 지정, 허용 대상 패치, InferenceService(ModelCar) 예시
verify.sh       예측 파드 안에서 연결 테스트
```

`cluster/`, `namespace/` 는 `MODEL_NAMESPACE`, `TARGET_*` 자리표시자를 가진 base 이므로 그대로 적용하지 말고
overlay 를 만들어 쓰세요.

## 적용

```bash
# 0. 지원 여부 확인 (OVN-Kubernetes 필요)
oc api-resources | grep -E 'adminnetworkpolicies|egressfirewalls'

# 1. 새 모델 네임스페이스용 overlay 만들기
cp -r overlays/example overlays/<name>
#    overlays/<name>/cluster/kustomization.yaml    : 모델 ns, 허용 대상 ns/라벨/포트
#    overlays/<name>/namespaced/kustomization.yaml : namespace, 허용 대상 (위와 같은 값)
#    overlays/<name>/namespaced/inferenceservice.yaml : 모델 이미지, runtime, 리소스

# 2. 렌더링 확인 후 적용
oc kustomize overlays/<name>
oc apply -k overlays/<name>                 # cluster-admin 이 한 번에

# 권한을 나누는 경우
oc apply -k overlays/<name>/cluster         # cluster-admin
oc apply -k overlays/<name>/namespaced      # 프로젝트 관리자
```

> 정책을 먼저 적용하고 InferenceService 를 배포하면, 모델이 뜨는 순간부터 격리된 상태가 됩니다.

### 허용 대상 추가

허용 대상 하나당 두 곳에 같은 값을 넣어야 합니다.

1. `namespaced/kustomization.yaml` 의 `model-allow-target` 패치 `egress` 목록에 항목 추가
2. `cluster/kustomization.yaml` 의 AdminNetworkPolicy 에 `Pass` 규칙 추가 (`deny-other-namespaces` **앞에**,
   `op: add`, `path: /spec/egress/3`)

AdminNetworkPolicy 에만 추가하면 NetworkPolicy 에서 막히고, NetworkPolicy 에만 추가하면 AdminNetworkPolicy 에서 막힙니다.

## 주의사항

- **포트는 서비스 포트가 아니라 파드의 컨테이너 포트(targetPort)** 입니다. NetworkPolicy 는 서비스 주소 변환(DNAT) 이후에
  평가되므로, 대상도 서비스가 아니라 **파드 라벨**로 지정합니다. DNS 도 같은 이유로 53 이 아니라 5353 입니다.
- **ModelCar** 는 노드(kubelet)가 이미지를 받으므로 파드 egress 와 무관합니다. S3/URI 방식으로 바꾸면
  storage-initializer 가 파드 안에서 다운로드하므로 해당 저장소를 허용해야 합니다.
- **들어오는 트래픽은 건드리지 않습니다** (`policyTypes: [Egress]`). Route 를 통한 추론 요청, 모니터링 수집은 그대로이고,
  NetworkPolicy 는 상태를 추적하므로 요청에 대한 응답도 허용됩니다.
- **토큰 인증(Require token authentication)과 충돌합니다.** InferenceService 에 토큰 인증을 켜면 RHOAI 가 예측 파드에
  인증 프록시 사이드카(kube-rbac-proxy / oauth-proxy)를 추가하는데, 이 사이드카는 **파드의 SA 토큰으로 API 서버를 호출**합니다.
  이 구성(토큰 미마운트 + API 서버 차단)에서는 인증이 실패합니다. 선택지:
  1. 인증은 앞단(API Gateway, Gateway API + Authorino 등)에서 처리하고 예측 파드는 그대로 격리 (권장)
  2. 사이드카 인증을 쓴다면 SA 토큰 마운트를 허용하고, API 서버(노드 IP:6443)를 EgressFirewall `Allow`
     와 NetworkPolicy `ipBlock` 으로 열어야 합니다. 같은 파드의 모델 컨테이너도 API 서버에 닿게 되므로
     SA 의 RBAC 권한을 최소로 유지하세요.
- EgressFirewall 은 네임스페이스당 하나(`default`)만 가능합니다. 이미 있으면 합쳐야 합니다.
- AdminNetworkPolicy `priority` 는 OVN-Kubernetes 에서 0~99 (낮을수록 우선)이며 같은 우선순위끼리 겹치면 안 됩니다.
  네임스페이스마다 다른 값(예: 50, 51, ...)을 쓰세요.
- vLLM/HF 오프라인 env (`HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE`, `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK`)는
  네트워크가 막혀 있어도 시도 자체를 없애 타임아웃 지연과 불필요한 로그를 줄입니다.

## 검증 (클러스터)

```bash
./verify.sh kblife-models qwen3-14b-awq \
  vector-db.rag-system.svc:6333:allow \
  vector-db.rag-system.svc:9999:deny \
  some-svc.other-namespace.svc:8080:deny \
  huggingface.co:443:deny \
  10.0.0.10:443:deny            # 사내 다른 시스템 IP
```

추가로 확인할 것:

1. NetworkPolicy 를 지워도 (`oc delete networkpolicy -n kblife-models --all`) 다른 ns / 외부가 계속 `deny` 인지
   (AdminNetworkPolicy + EgressFirewall 동작 확인) → 확인 후 `oc apply -k overlays/<name>/namespaced` 로 복구
2. 추론이 정상인지: `oc get inferenceservice -n kblife-models`, Route 로 `/v1/models` 호출
3. 정책 상태: `oc get adminnetworkpolicy model-isolation-kblife-models -o yaml` 의 `status.conditions`,
   `oc get egressfirewall -n kblife-models` 의 `EgressFirewall Rules applied`
