#!/usr/bin/env bash
# 모델 네임스페이스(kbl-models, kbl-maas)의 NetworkPolicy 가 의도대로 동작하는지 확인한다.
#
# 사용법:
#   ./verify.sh egress  <namespace> <model> [host:port:allow|deny ...]
#   ./verify.sh ingress <namespace> <model> [unlabeled-namespace]
#
# egress : 모델 파드 안에서 TCP 연결을 시도한다 (조회만, 클러스터를 바꾸지 않는다)
#          대상을 주지 않으면 현재 설정 기준 기본 세트로 시험한다
#          (API 서버 6443 허용, 노드 22·다른 ns 서비스·클러스터 밖 거부, kbl-maas 는 OTel collector 4317 허용)
# ingress: 임시 클라이언트 파드(oc run --rm)를 띄워 모델 파드로 연결을 시도한다 (파드를 만들므로 실행 전 확인)
#          kbl-models: 같은 ns(playground-caller 토큰) / 등록 ns(kai-agent, agent 토큰) / 라벨 없는 ns
#                      → 8443 토큰 200, 무토큰 401, 8080 차단, 라벨 없는 ns 는 8443 도 차단
#          kbl-maas  : 등록 ns·라벨 없는 ns → vLLM 포트 차단 (gateway 를 거쳐야만 호출)
#
# 예:
#   ./verify.sh egress  kbl-models qwen3-4b-instruct
#   ./verify.sh egress  kbl-models qwen3-4b-instruct vector-db.rag-system.svc:6333:allow 10.0.0.10:443:deny
#   ./verify.sh ingress kbl-models qwen3-4b-instruct default
#   ./verify.sh egress  kbl-maas   qwen3-1-7b
#
# 환경 변수 (필요할 때만):
#   POD_SELECTOR  모델 파드 라벨 셀렉터 (기본: ISVC 라벨 → 없으면 LLMInferenceService 라벨 순으로 찾는다)
#   CONTAINER     exec 할 컨테이너 (기본: ISVC kserve-container, LLMInferenceService main)
#   CLIENT_IMAGE  ingress 임시 파드 이미지, curl 필요 (기본: registry.access.redhat.com/ubi9/ubi-minimal. 폐쇄망이면 Nexus 경로)
#   CONSUMER_NS   등록(model-consumer) 네임스페이스 (기본: kai-agent),  CONSUMER_SA (기본: agent)
#   MAAS_PORT     kbl-maas vLLM 컨테이너 포트 (기본: 8000)
#   ASSUME_YES=1  ingress 확인 프롬프트 생략
set -euo pipefail

usage() { sed -n '2,31s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2; exit 2; }
[[ $# -lt 3 ]] && usage
mode="$1" namespace="$2" model="$3"
shift 3

CLIENT_IMAGE="${CLIENT_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal}"
CONSUMER_NS="${CONSUMER_NS:-kai-agent}"
CONSUMER_SA="${CONSUMER_SA:-agent}"
MAAS_PORT="${MAAS_PORT:-8000}"

failed=0
report() { # <설명> <기대> <실제>
    if [[ "$2" == "$3" ]]; then
        printf '  OK    %-55s %s\n' "$1" "$3"
    else
        printf '  FAIL  %-55s expected %s, got %s\n' "$1" "$2" "$3"
        failed=1
    fi
}

# 모델 파드 찾기 (Running 만). 결과: pod, kind(isvc|llmisvc)
find_pod() {
    local sel
    if [[ -n "${POD_SELECTOR:-}" ]]; then
        sel="${POD_SELECTOR}"; kind=custom
        pod="$(oc get pod -n "${namespace}" -l "${sel}" --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    else
        # Raw(ISVC)
        sel="serving.kserve.io/inferenceservice=${model}"; kind=isvc
        pod="$(oc get pod -n "${namespace}" -l "${sel}" --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [[ -z "${pod}" ]]; then
            # llm-d(LLMInferenceService) 워크로드 파드. 라벨은 업스트림 KServe 기준 (3.5 미확인 — 다르면 POD_SELECTOR 로 지정)
            sel="app.kubernetes.io/name=${model},app.kubernetes.io/component=llminferenceservice-workload"; kind=llmisvc
            pod="$(oc get pod -n "${namespace}" -l "${sel}" --field-selector=status.phase=Running \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        fi
    fi
    if [[ -z "${pod}" ]]; then
        echo "Running 모델 파드가 없다: ${namespace}/${model}" >&2
        echo "  - 모델이 정지 상태인지 확인: annotation serving.kserve.io/stop (변경은 Git 으로)" >&2
        echo "  - 라벨이 다르면 POD_SELECTOR=<셀렉터> 로 지정" >&2
        exit 2
    fi
    if [[ -z "${CONTAINER:-}" ]]; then
        case "${kind}" in
            llmisvc) CONTAINER=main ;;
            *)       CONTAINER=kserve-container ;;
        esac
    fi
    pod_ip="$(oc get pod -n "${namespace}" "${pod}" -o jsonpath='{.status.podIP}')"
    echo "모델 파드: ${namespace}/${pod} (${kind}, ${pod_ip}, container ${CONTAINER})"
}

# ---------------------------------------------------------------- egress
# 파드 안에서 DNS 해석 → TCP 연결. 출력: allow | deny | nxdomain
# (vLLM 이미지에는 curl 이 없을 수 있으므로 python 소켓을 쓴다. 값은 argv 로 넘긴다)
probe_from_pod() {
    oc exec -n "${namespace}" "${pod}" -c "${CONTAINER}" -- python3 -c '
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    addr = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)[0][4]
except OSError:
    print("nxdomain"); sys.exit(0)
try:
    socket.create_connection(addr[:2], timeout=5).close(); print("allow")
except OSError:
    print("deny")
' "$1" "$2" 2>/dev/null || echo "exec-error"
}

default_egress_targets() {
    local api node
    api="$(oc get endpointslice -n default -l kubernetes.io/service-name=kubernetes \
        -o jsonpath='{.items[0].endpoints[0].addresses[0]}')"
    node="$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
    targets=(
        "${api}:6443:allow"                         # API 서버 (35: machineNetwork CIDR 6443)
        "${node}:22:deny"                           # 같은 대역이라도 6443 외 포트는 막힘
        "console.openshift-console.svc:443:deny"    # 다른 네임스페이스
        "quay.io:443:deny"                          # 클러스터 밖
    )
    if [[ "${namespace}" == "kbl-maas" ]]; then
        targets+=("data-science-collector-collector.redhat-ods-monitoring.svc:4317:allow")  # trace (35)
    fi
}

run_egress() {
    find_pod
    local targets=("$@")
    [[ ${#targets[@]} -eq 0 ]] && default_egress_targets
    echo "[egress] ${namespace}/${model} →"
    local t expect hostport host port actual
    for t in "${targets[@]}"; do
        expect="${t##*:}"; hostport="${t%:*}"; host="${hostport%:*}"; port="${hostport##*:}"
        if [[ "${expect}" != allow && "${expect}" != deny ]]; then
            echo "  기대값은 allow|deny: ${t}" >&2; failed=1; continue
        fi
        actual="$(probe_from_pod "${host}" "${port}")"
        # 이름 해석 실패는 정책 차단과 구분한다 (대상이 없거나 이름이 틀렸을 수 있음)
        report "${host}:${port}" "${expect}" "${actual}"
    done
}

# ---------------------------------------------------------------- ingress
# 임시 파드를 <ns> 에서 <sa> 로 띄워 curl 을 실행한다. 출력: 'HTTP코드' 들 (000 = 연결 실패)
run_client() { # <ns> <sa> <script>
    local ns="$1" sa="$2" script="$3" name
    name="netpol-verify-$(date +%s)-${RANDOM}"
    local overrides
    overrides="$(cat <<JSON
{"spec":{"serviceAccountName":"${sa}","automountServiceAccountToken":true,
 "securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"${name}","image":"${CLIENT_IMAGE}","command":["/bin/sh","-c",$(printf '%s' "${script}" | python3 -I -c 'import json,sys;print(json.dumps(sys.stdin.read()))')],
  "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}
JSON
)"
    oc run "${name}" -n "${ns}" --image="${CLIENT_IMAGE}" --restart=Never --rm -i --quiet \
        --overrides="${overrides}" 2>/dev/null | tr -d '\r' || true
}

# 결과를 한 줄에 'tok noTok direct' 순서로 낸다
client_script_models() { # <ip>
    cat <<SH
T=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null)
c() { curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "\$@" || true; }
echo "\$(c -H "Authorization: Bearer \$T" https://$1:8443/v1/models) \$(c https://$1:8443/v1/models) \$(c http://$1:8080/metrics)"
SH
}

client_script_connect() { # <ip> <port>  → allow | deny
    cat <<SH
if timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2' 2>/dev/null; then echo allow; else echo deny; fi
SH
}

confirm() {
    [[ "${ASSUME_YES:-}" == 1 ]] && return 0
    echo "임시 파드를 만든다 (끝나면 삭제): $*"
    read -r -p "계속할까요? [y/N] " ans
    [[ "${ans}" == y || "${ans}" == Y ]] || { echo "취소"; exit 1; }
}

run_ingress() {
    local unlabeled="${1:-}"
    find_pod
    local out tok notok direct
    if [[ "${kind}" == isvc ]]; then
        confirm "${namespace}(playground-caller), ${CONSUMER_NS}(${CONSUMER_SA})${unlabeled:+, ${unlabeled}(default)} — 이미지 ${CLIENT_IMAGE}"
        echo "[ingress] → ${namespace}/${model} (${pod_ip}) : 8443 토큰 / 8443 무토큰 / 8080"

        read -r tok notok direct <<<"$(run_client "${namespace}" playground-caller "$(client_script_models "${pod_ip}")")"
        report "같은 ns (playground-caller) 8443 토큰"   200 "${tok:-none}"
        report "같은 ns (playground-caller) 8443 무토큰" 401 "${notok:-none}"
        report "같은 ns 8080 (vLLM 직결)"               000 "${direct:-none}"

        read -r tok notok direct <<<"$(run_client "${CONSUMER_NS}" "${CONSUMER_SA}" "$(client_script_models "${pod_ip}")")"
        report "등록 ns ${CONSUMER_NS} 8443 토큰"   200 "${tok:-none}"
        report "등록 ns ${CONSUMER_NS} 8443 무토큰" 401 "${notok:-none}"
        report "등록 ns ${CONSUMER_NS} 8080"        000 "${direct:-none}"

        if [[ -n "${unlabeled}" ]]; then
            read -r tok notok direct <<<"$(run_client "${unlabeled}" default "$(client_script_models "${pod_ip}")")"
            report "라벨 없는 ns ${unlabeled} 8443" 000 "${tok:-none}"
            report "라벨 없는 ns ${unlabeled} 8080" 000 "${direct:-none}"
        fi
    else
        confirm "${CONSUMER_NS}(${CONSUMER_SA})${unlabeled:+, ${unlabeled}(default)} — 이미지 ${CLIENT_IMAGE}"
        echo "[ingress] → ${namespace}/${model} (${pod_ip}) : vLLM ${MAAS_PORT} 직접 연결 (gateway 우회)"
        out="$(run_client "${CONSUMER_NS}" "${CONSUMER_SA}" "$(client_script_connect "${pod_ip}" "${MAAS_PORT}")")"
        report "등록 ns ${CONSUMER_NS} → ${MAAS_PORT}" deny "${out:-none}"
        if [[ -n "${unlabeled}" ]]; then
            out="$(run_client "${unlabeled}" default "$(client_script_connect "${pod_ip}" "${MAAS_PORT}")")"
            report "라벨 없는 ns ${unlabeled} → ${MAAS_PORT}" deny "${out:-none}"
        fi
    fi
}

case "${mode}" in
    egress)  run_egress "$@" ;;
    ingress) run_ingress "$@" ;;
    *)       usage ;;
esac
exit "${failed}"
