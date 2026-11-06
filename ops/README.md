# Ops팀: RHOAI 플랫폼과 모델 네임스페이스

NFD, NVIDIA GPU Operator, RHOAI Operator, OpenShift GitOps 는 이미 설치되어 있다고 가정합니다.
모든 파일은 값이 채워진 YAML 입니다. `nexus.internal.example:5000`, digest(`sha256:000…`), CA PEM, 그룹 이름
`kbl-ai-developers` 같은 예시 값은 사이트 값으로 바꿔서 씁니다.

## 디렉터리

```
platform/                          클러스터 설정 (Argo CD: kbl-ops-platform)
  datasciencecluster.yaml          DSC v2: dashboard, kserve(Standard)
  hardwareprofile-gpu.yaml         HardwareProfile gpu-1x
  hardwareprofile-gpu-2x.yaml      HardwareProfile gpu-2x (tensor parallel)
  registry-ca.yaml                 Nexus CA (ConfigMap + image.config additionalTrustedCA)
  rbac-ai.yaml                     AI팀 HardwareProfile 조회 권한 (redhat-ods-applications)
  mirror/imageset-config.yaml      oc-mirror 입력 파일 (동기화 대상 아님)
kbl-models/                        모델 네임스페이스 (Argo CD: kbl-ops-kbl-models)
  00-namespace.yaml
  10-resourcequota.yaml            네임스페이스 GPU quota
  20-adminnetworkpolicy.yaml
  21-egressfirewall.yaml
  30-serviceaccount.yaml           model-serving (토큰 미마운트, nexus-pull)
  31-, 32-networkpolicy-*.yaml     egress 기본 차단, DNS 허용
  33-networkpolicy-ingress.yaml    ingress 허용: 소비 네임스페이스(kbl.io/model-consumer=true), 메트릭 수집
  40-rbac-ai.yaml                  AI팀 Role/RoleBinding
  network/allow-<ns>-<대상>.yaml   허용 대상별 NetworkPolicy, 접근 가능한 모델 목록 (AI팀 요청)
  runtimes/vllm-<등급>-<버전>.yaml
gitops/
  appprojects.yaml                 AppProject kbl-ops, kbl-ai (직접 oc apply)
  root-application.yaml            app-of-apps 루트 kbl-root (직접 oc apply)
  apps/                            Application 3개 (sync-wave 0 → 1 → 2)
network-isolation/                 네트워크 격리 설계 설명, verify.sh
```

## 처음 구성

```bash
# 1. 이미지 미러링 (폐쇄망, platform/mirror/imageset-config.yaml 참고)

# 2. 기존 DSC 가 있으면 platform/datasciencecluster.yaml 과 합친다
oc get dsc -o yaml
oc apply --dry-run=server -f deploy/ops/platform/

# 3. Argo CD 준비
#    - 기본 인스턴스는 클러스터 범위 리소스 권한이 제한되어 있으므로 application controller 에 필요한 권한을 먼저 준다
#    - app-of-apps 가 wave 순서를 지키도록 Application health check 를 설정한다 (아래)

# 4. 프로젝트와 루트 Application
oc apply -f deploy/ops/gitops/appprojects.yaml
oc apply -f deploy/ops/gitops/root-application.yaml
#    kbl-root 가 kbl-ops-platform(wave 0) → kbl-ops-kbl-models(wave 1) → kbl-ai(wave 2) 순서로 만든다.
#    kbl-ops-platform 은 자동 동기화가 아니므로 내용을 확인하고 직접 Sync 한다

# 5. kbl-models 가 생기면 pull secret (모델 파드는 secret 이 생길 때까지 ImagePullBackOff 로 기다린다)
oc create secret docker-registry nexus-pull -n kbl-models \
  --docker-server=nexus.internal.example:5000 --docker-username=<계정> --docker-password=<토큰>
```

Argo CD 2.x 부터 Application 의 health 를 기본으로 보지 않아서, 설정이 없으면 app-of-apps 가 앞 wave 를 기다리지 않습니다.
OpenShift GitOps 의 `ArgoCD` CR(`openshift-gitops`)에 추가합니다:

```yaml
spec:
  resourceHealthChecks:
    - group: argoproj.io
      kind: Application
      check: |
        hs = {}
        hs.status = "Progressing"
        hs.message = ""
        if obj.status ~= nil and obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
        return hs
```

Secret 은 Git 에 두지 않습니다 (External Secrets / Sealed Secrets 를 쓰면 `kbl-models/` 에 추가).
GitOps 없이 적용할 때는 같은 순서로 `oc apply -f` (`kbl-models/` 는 `-R`) 합니다.

수동으로 확인할 것:

```bash
# ModelCar 사용 설정 (enableModelcar: true)
oc get cm inferenceservice-config -n redhat-ods-applications -o jsonpath='{.data.storageInitializer}'
# GPU 노드
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
# vLLM 메트릭 수집(User Workload Monitoring). 기존 내용을 덮어쓰지 않도록 매니페스트로 두지 않는다
oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}'
```

## 운영

외부에서 이미 빌드된 ModelCar 이미지(예: Red Hat `rhai/modelcar-*`) 반입 절차: [docs/modelcar-import.md](../../docs/modelcar-import.md)

### 런타임 추가 (AI팀 요청)

```bash
# 1. 승인한 이미지를 등급 repo 로 반입 (digest 유지)
skopeo copy --all docker://registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:<digest> \
  docker://nexus.internal.example:5000/vllm-fast/vllm-cuda-rhel9@sha256:<digest>
# 2. runtimes/vllm-ga-3-2-4.yaml 를 복사해 이름(vllm-<등급>-<버전>), 라벨, support-status, runtime-version, image 수정 → 커밋
```

- 이름에 버전을 넣으므로 여러 버전이 같이 있어도 되고, 새 런타임을 추가해도 기존 모델은 재시작되지 않습니다
- `support-status`: ga=`supported`, fast=`limited`, upstream=`unsupported`
- upstream(커뮤니티 vLLM) 런타임은 `runtimes/vllm-upstream-0-28-0.yaml` 을 기준으로 만듭니다. 임의 UID 대응
  (`HOME`/`XDG_CACHE_HOME`/`HF_HOME` → `/tmp`), `/dev/shm`, `autoSelect: false` 가 GA 런타임과 다릅니다.
  노드 NVIDIA 드라이버가 이미지의 CUDA 버전을 지원하는지 먼저 확인합니다
- 모든 런타임에 `/dev/shm`(Memory emptyDir)을 둡니다. AI팀이 어떤 HardwareProfile(gpu-2x 의 tensor parallel 포함)과
  조합해도 동작해야 하기 때문입니다
- 런타임 삭제는 자동 prune 하지 않습니다. 쓰는 모델이 없는지 확인하고 `oc delete servingruntime -n kbl-models <이름>`

### 다른 네임스페이스 접근 (AI팀 요청)

- 이미 있는 대상: `network/allow-<ns>-<대상>.yaml` 의 `values` 에 모델 이름 추가 (ANP 는 그대로)
- 새 대상: `network/allow-<ns>-<대상>.yaml` 추가와 `20-adminnetworkpolicy.yaml` 의 `pass-<ns>-<대상>` 규칙 추가를 같은 커밋으로 합니다
- 자세한 내용: [network-isolation/README.md](network-isolation/README.md#허용-대상-추가)

### 에이전트 네임스페이스 등록

모델 파드는 `kbl.io/model-consumer=true` 라벨이 있는 네임스페이스에서만 호출할 수 있습니다 (`33-networkpolicy-ingress.yaml`).

```bash
oc label namespace <에이전트 ns> kbl.io/model-consumer=true
```

에이전트 네임스페이스에 egress 제한이 있다면 그쪽에서도 `kbl-models` 의 8080 을 열어야 합니다.
Gateway/MaaS 를 도입하면 Gateway 네임스페이스에만 라벨을 붙이고 에이전트는 Gateway 를 호출합니다.

### GPU quota

kbl-models 전체 상한은 `10-resourcequota.yaml`. 롤링 업데이트 중에는 GPU 가 하나 더 필요하므로 여유를 둡니다.

## 점검

```bash
oc get isvc,servingruntime,pods -n kbl-models
oc describe quota -n kbl-models
oc get isvc -n kbl-models -L kbl.io/runtime-tier,kbl.io/model-source
deploy/ops/network-isolation/verify.sh kbl-models qwen3-4b-instruct huggingface.co:443:deny
```
