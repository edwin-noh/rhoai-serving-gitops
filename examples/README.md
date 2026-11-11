# 예시 (동기화하지 않음)

| 파일 | 대상 | 내용 |
|---|---|---|
| `agent-client.yaml` | 에이전트팀 (에이전트 네임스페이스) | egress NetworkPolicy, MaaS API 키 Secret, ISVC(SA 토큰)·MaaS(API 키) 호출 Job |

전제: Ops 가 `deploy/ops/consumers/<에이전트 ns>.yaml` 로 등록해 두었다 (네트워크 라벨 + SA + 호출 권한).

## Python (OpenAI SDK)

```python
import httpx
from openai import OpenAI

SA = "/var/run/secrets/kubernetes.io/serviceaccount"

# ISVC (kbl-models): SA 토큰 + OpenShift service CA. 토큰은 주기적으로 갱신되므로 요청 때마다 읽는다
isvc = OpenAI(
    base_url="https://qwen3-4b-instruct-predictor.kbl-models.svc:8443/v1",
    api_key=open(f"{SA}/token").read(),
    http_client=httpx.Client(verify="/etc/service-ca/service-ca.crt"),   # ConfigMap openshift-service-ca.crt 마운트
)
isvc.chat.completions.create(model="qwen3-4b-instruct", messages=[{"role": "user", "content": "안녕"}])

# MaaS (kbl-maas): API 키, model 은 /v1/models 의 id
maas = OpenAI(base_url="https://maas.<apps 도메인>/v1", api_key="sk-oai-...")
maas.chat.completions.create(model="publishers/kbl-maas/models/qwen3-4b-instruct",
                             messages=[{"role": "user", "content": "안녕"}])
```
