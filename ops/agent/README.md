# 모델 호출자(에이전트 네임스페이스) 등록

`kbl-models` 의 InferenceService 는 토큰 인증이 필수다. 호출하려면 **네트워크**와 **토큰 권한**이 모두 필요하고,
이 폴더의 파일 하나(`<에이전트 ns>.yaml`)가 둘을 함께 연다. Argo CD 앱: `../gitops/apps/12-kbl-ops-agent.yaml`.

| 항목 | 리소스 | 효과 |
|---|---|---|
| 네트워크 | Namespace 라벨 `kblife.co.kr/model-consumer: "true"` | `kbl-models` 의 8443(kube-rbac-proxy)로 접속 가능 (`../kbl-models/36-netpol-ingress.yaml`) |
| 신원 | ServiceAccount (에이전트 ns) | 에이전트 파드가 이 SA 로 실행, 토큰을 Bearer 로 전송 |
| 권한 | RoleBinding (ns `kbl-models`) → Role `model-caller` | `kbl-models` 의 **모든** ISVC 호출 가능 (`../kbl-models/50-model-callers.yaml`) |

모델을 추가할 때는 할 일이 없다. 호출자를 추가할 때만 파일을 하나 추가한다.
MaaS(llm-d) 모델은 Kubernetes RBAC 를 쓰지 않는다 — `../maas-policy/` 의 Subscription/AuthPolicy 에 사용자 그룹을 넣는다.

## 등록
1. `kai-agent.yaml` 을 복사해 `<에이전트 ns>.yaml` 로 저장하고 네임스페이스·SA 이름을 바꾼다
2. 커밋 → `kbl-ops-agent` 앱이 동기화
3. 확인
   ```bash
   oc get ns <에이전트 ns> -L kblife.co.kr/model-consumer
   oc auth can-i get inferenceservices/<모델> -n kbl-models --as=system:serviceaccount:<에이전트 ns>:<SA>   # yes
   ```
4. 에이전트팀에 클라이언트 예시 전달: `../../examples/agent-client.yaml`

## 워크벤치 프로젝트로 쓰기 (AI 개발자)

AI 개발자(`kbl-ai-developers`)는 프로젝트를 만들 수 없고(`../platform/rbac-self-provisioner.yaml`), 여기 등록된 네임스페이스에서만 작업한다.
`kai-agent.yaml` 처럼 아래를 넣으면 RHOAI 대시보드에서 그 프로젝트의 워크벤치를 쓸 수 있다.

| 항목 | 리소스 | 효과 |
|---|---|---|
| 대시보드 표시 | Namespace 라벨 `opendatahub.io/dashboard: "true"` | 대시보드 Projects 목록에 나온다 |
| 권한 | RoleBinding `kbl-ai-workbench` → ClusterRole `kbl-ai-workbench` | 워크벤치(Notebook)·스토리지(PVC)·연결(Secret/ConfigMap) 관리, 파드·로그 조회. Deployment/Pod 직접 생성 불가 |
| 조회 | RoleBinding `kbl-ai-developers-view` → ClusterRole `view` | 대시보드가 프로젝트 화면을 그릴 때 읽는 리소스 (없으면 Create workbench 가 막힌다) |
| 모델 호출 | 호출 RoleBinding 에 Group `system:serviceaccounts:<ns>` | 워크벤치 파드(노트북마다 SA)가 자기 SA 토큰으로 ISVC 호출 |

근거: RHOAI 3.5 *Working on projects* 5장 "Manage access to projects" (워크벤치 커스텀 롤).
대시보드가 쓰는 verb 는 문서에 목록이 없어 대시보드로 직접 만들어 보며 확인한다. 권한 오류가 나면 해당 리소스·verb 를 롤에 추가한다.

## 해지
- 파일을 지우고 커밋한다. 앱이 `prune: false` 라 리소스는 남으므로 **직접 지운다**:
  ```bash
  oc delete rolebinding caller-<에이전트 ns> -n kbl-models
  oc label namespace <에이전트 ns> kblife.co.kr/model-consumer-
  ```
  (Namespace 는 `Delete=false` 라 Argo 가 지우지 않는다. SA 는 에이전트팀과 협의해 삭제)
- 이미 발급된 SA 토큰은 RoleBinding 을 지우는 즉시 403 이 된다 (프록시가 매 요청 SubjectAccessReview)
