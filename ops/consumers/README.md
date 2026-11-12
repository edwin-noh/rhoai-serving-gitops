# 모델 호출자(에이전트 네임스페이스) 등록

`kbl-models` 의 InferenceService 는 토큰 인증이 필수다. 호출하려면 **네트워크**와 **토큰 권한**이 모두 필요하고,
이 폴더의 파일 하나(`<에이전트 ns>.yaml`)가 둘을 함께 연다. Argo CD 앱: `../gitops/apps/12-kbl-ops-consumers.yaml`.

| 항목 | 리소스 | 효과 |
|---|---|---|
| 네트워크 | Namespace 라벨 `kbl.io/model-consumer: "true"` | `kbl-models` 의 8443(kube-rbac-proxy)로 접속 가능 (`../kbl-models/36-netpol-model-ingress.yaml`) |
| 신원 | ServiceAccount (에이전트 ns) | 에이전트 파드가 이 SA 로 실행, 토큰을 Bearer 로 전송 |
| 권한 | RoleBinding (ns `kbl-models`) → Role `model-caller` | `kbl-models` 의 **모든** ISVC 호출 가능 (`../kbl-models/50-model-callers.yaml`) |

모델을 추가할 때는 할 일이 없다. 호출자를 추가할 때만 파일을 하나 추가한다.
MaaS(llm-d) 모델은 Kubernetes RBAC 를 쓰지 않는다 — `../maas-policy/` 의 Subscription/AuthPolicy 에 사용자 그룹을 넣는다.

## 등록
1. `kbl-poc-agent.yaml` 을 복사해 `<에이전트 ns>.yaml` 로 저장하고 네임스페이스·SA 이름을 바꾼다
2. 커밋 → `kbl-ops-consumers` 앱이 동기화
3. 확인
   ```bash
   oc get ns <에이전트 ns> -L kbl.io/model-consumer
   oc auth can-i get inferenceservices/<모델> -n kbl-models --as=system:serviceaccount:<에이전트 ns>:<SA>   # yes
   ```
4. 에이전트팀에 클라이언트 예시 전달: `../../examples/agent-client.yaml`

## 해지
- 파일을 지우고 커밋한다. 앱이 `prune: false` 라 리소스는 남으므로 **직접 지운다**:
  ```bash
  oc delete rolebinding caller-<에이전트 ns> -n kbl-models
  oc label namespace <에이전트 ns> kbl.io/model-consumer-
  ```
  (Namespace 는 `Delete=false` 라 Argo 가 지우지 않는다. SA 는 에이전트팀과 협의해 삭제)
- 이미 발급된 SA 토큰은 RoleBinding 을 지우는 즉시 403 이 된다 (프록시가 매 요청 SubjectAccessReview)
