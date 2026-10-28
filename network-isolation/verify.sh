#!/usr/bin/env bash
# 모델 예측 파드 안에서 TCP 연결을 시도해 네트워크 격리가 의도대로 동작하는지 확인한다.
#
# 사용법: ./verify.sh <namespace> <inferenceservice> <host:port:expect>...
#   expect: allow(연결 성공해야 함) | deny(연결 실패해야 함)
# 예:
#   ./verify.sh kblife-models qwen3-14b-awq \
#     vector-db.rag-system.svc:6333:allow \
#     other-svc.other-ns.svc:8080:deny \
#     huggingface.co:443:deny \
#     8.8.8.8:53:deny
set -euo pipefail

if [[ $# -lt 3 ]]; then
    sed -n '2,12s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
fi
namespace="$1"
isvc="$2"
shift 2

pod="$(oc get pod -n "${namespace}" -l "serving.kserve.io/inferenceservice=${isvc}" \
    -o jsonpath='{.items[0].metadata.name}')"
echo "파드: ${namespace}/${pod}"

failed=0
for target in "$@"; do
    expect="${target##*:}"
    hostport="${target%:*}"
    host="${hostport%:*}"
    port="${hostport##*:}"
    # vLLM 이미지에는 curl 이 없을 수 있으므로 python 소켓으로 확인한다
    if oc exec -n "${namespace}" "${pod}" -c kserve-container -- python3 -c "
import socket, sys
try:
    socket.create_connection(('${host}', ${port}), timeout=5).close()
except OSError:
    sys.exit(1)
" >/dev/null 2>&1; then
        actual=allow
    else
        actual=deny
    fi
    if [[ "${actual}" == "${expect}" ]]; then
        echo "  OK    ${host}:${port} (${actual})"
    else
        echo "  FAIL  ${host}:${port} (expected ${expect}, got ${actual})"
        failed=1
    fi
done
exit "${failed}"
