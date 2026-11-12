# 모델 네임스페이스 네트워크 격리 (NetworkPolicy)

모델 네임스페이스(`kbl-models` Raw, `kbl-maas` MaaS)는 **NetworkPolicy 3개**로 격리한다.
NetworkPolicy 는 Ops팀이 Git 으로만 만들고(AI팀 Role 에는 NetworkPolicy 권한 없음), 그 밖에는 RHOAI operator(예: Gen AI playground)만 만든다.

## 구성

| 파일 | 대상 | 역할 |
|---|---|---|
| `34-netpol-default-deny.yaml` | 네임스페이스의 모든 파드 | Ingress·Egress 기본 차단. **클러스터 밖으로 나가는 것도 여기서 막힌다** |
| `35-netpol-egress.yaml` | 모든 파드 | DNS(5353), 같은 네임스페이스, API 서버 = 머신 네트워크 CIDR **6443 만** |
| `36-netpol-model-ingress.yaml` (Raw) | 모델 파드 | 8443(토큰 인증 프록시) ← 같은 ns + `kbl.io/model-consumer=true` ns / 8080(vLLM 직결) ← 모니터링만 |
| `36-netpol-ingress.yaml` (MaaS) | 모든 파드 | ← MaaS gateway(`openshift-ingress`), 같은 ns(EPP → vLLM), 모니터링 |
| `network/allow-<ns>-<대상>.yaml` (Raw) | 지정 모델 | 다른 네임스페이스 대상 egress (대상 하나 = 파일 하나) |

호출 허용 요약 (Raw):

| 출발 | 8443 | 8080 |
|---|---|---|
| 같은 네임스페이스 (Gen AI playground — AI팀 admin 만 운영) | ✅ 토큰 필요 | ❌ |
| Ops 가 허용한 네임스페이스 (`../consumers/<ns>.yaml`) | ✅ 토큰 필요 | ❌ |
| 모니터링 | — | ✅ |
| 그 외 네임스페이스, 클러스터 밖 | ❌ | ❌ |

→ **토큰 없이 vLLM 에 닿는 경로가 없다.** 8080 을 열면 `<모델>-metrics` Service 로 토큰 없이 호출되므로(PoC 에서 확인) 같은 ns 에도 열지 않는다.
Ops 점검은 `oc port-forward`(NetworkPolicy 영향 없음)로 한다.

## 왜 NetworkPolicy 만으로 충분한가 / 감수하는 점

- 예전 구성(AdminNetworkPolicy + EgressFirewall + NetworkPolicy)은 "누가 NetworkPolicy 를 추가해 열어도 막는다" 는 이중 방어였다.
  NetworkPolicy 를 만들 수 있는 주체가 Ops(Git)와 operator 로 한정되므로 관리 단순화를 택했다
- **감수**: NetworkPolicy 는 합산이라 operator 가 **모델 파드**를 대상으로 허용 NP 를 만들면 열린다.
  지금 확인된 operator NP(`genai-pgvector`, `lsd-genai-playground-network-policy`)는 playground 파드만 대상으로 한다. 주기 점검:
  ```bash
  oc get netpol -n kbl-models -o custom-columns='NAME:.metadata.name,ARGO:.metadata.annotations.argocd\.argoproj\.io/tracking-id,OWNER:.metadata.ownerReferences[0].kind,TARGET:.spec.podSelector'
  ```
  `ARGO` 가 비어 있고 `TARGET` 이 모델 파드(`serving.kserve.io/inferenceservice`)를 고르면 검토한다
- Argo CD selfHeal 은 Git 에 있는 정책이 바뀌면 되돌리지만, **Git 밖에서 새로 생긴 NetworkPolicy 는 지우지 않는다**

## 허용 대상 추가 (모델 → 다른 네임스페이스)

- 기존 대상에 모델 추가: `network/allow-<ns>-<대상>.yaml` 의 `values` 에 모델 이름 한 줄
- 새 대상: `network/allow-<ns>-<대상>.yaml` 파일 하나 추가. 대상은 서비스가 아니라 **파드 라벨 + 컨테이너 포트(targetPort)**
- 목록은 Ops 폴더에서 관리한다 (ISVC 라벨로 opt-in 하게 하면 AI팀이 스스로 네트워크를 열 수 있다)

## 주의사항

- **포트는 서비스 포트가 아니라 컨테이너 포트**다. NetworkPolicy 는 DNAT 이후 평가된다 (DNS 도 53 이 아니라 5353, API 서버도 443 이 아니라 6443)
- **API 서버**: NetworkPolicy 에는 노드 셀렉터가 없어 머신 네트워크 CIDR(`install-config` 의 `machineNetwork`) 하나를 6443 으로 연다.
  master 수·교체와 무관하다. 사이트 값: `oc get cm cluster-config-v1 -n kube-system -o jsonpath='{.data.install-config}' | grep -A1 machineNetwork`
- **토큰 인증(kube-rbac-proxy)**: 프록시가 파드 SA 토큰으로 TokenReview/SubjectAccessReview 를 보낸다 → ISVC `automountServiceAccountToken: true`,
  SA 에 `system:auth-delegator`(`../platform/rbac-model-serving-auth.yaml`). 같은 파드의 모델 컨테이너도 API 서버에 닿지만 SA 권한은 auth-delegator 뿐
- **ModelCar** 는 노드(kubelet)가 이미지를 받으므로 파드 egress 와 무관하다. S3/URI 방식이면 storage-initializer 가 파드 안에서 받으므로 저장소를 허용해야 한다
- **playground**: AI팀 admin(`kbl-ai-admins`, `../kbl-models/42-rbac-ai-admin.yaml`)만 만들고 쓴다. 모델 호출 토큰은 Secret `playground-caller-token`
  (Gen AI studio → AI asset endpoints → Create endpoint 에 입력). playground 도 같은 ns 의 8443 + 토큰으로만 모델을 부른다
- vLLM/HF 오프라인 env (`HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE`, `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK`)는 시도 자체를 없애 타임아웃 지연을 줄인다

## 검증 (클러스터)

```bash
# 모델 파드 안에서 나가는 연결 (allow/deny 기대값)
./verify.sh kbl-models qwen3-4b-instruct \
  vector-db.rag-system.svc:6333:allow \
  some-svc.other-namespace.svc:8080:deny \
  huggingface.co:443:deny \
  10.0.0.10:443:deny            # 사내 다른 시스템 IP
```

PoC 확인 결과 (2026-11-12):

| 시험 | 결과 |
|---|---|
| 등록 ns(`kbl-poc-agent`) → 8443 토큰 / 무토큰 / 8080 | 200 / 401 / 차단 |
| 라벨 없는 ns → 8443 / 8080 | 연결 차단 / 차단 |
| 같은 ns(`playground-caller` 토큰) → 8443 / 무토큰 / 8080 | 200 / 401 / 차단 |
| 모델 파드 → API 서버 6443 / quay.io / 노드 22 | 허용 / 차단 / 차단 |
| `kbl-maas`: 다른 ns → 파드 / 같은 ns → 파드 | 차단 / 허용 |
