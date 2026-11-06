# 모델 카탈로그

> 자동 생성 파일입니다. 직접 고치지 말고 `uv run python scripts/model-catalog.py` 로 다시 만드세요.

에이전트에서는 엔드포인트를 OpenAI 호환 `base_url` 로, 모델 이름을 `model` 로 씁니다.
호출하려면 에이전트 네임스페이스에 `kbl.io/model-consumer=true` 라벨이 필요합니다 (Ops팀에 요청).
런타임 등급 `upstream` 은 Red Hat 지원 대상이 아니고, `tool calling` 이 `-` 인 모델은 `tools` 요청을 처리하지 않습니다.

| 모델 (model) | 설명 | 엔드포인트 (OpenAI 호환) | 최대 컨텍스트 | tool calling | 런타임 등급 | 출처 | 런타임 | GPU |
|---|---|---|---|---|---|---|---|---|
| `gemma-4-26b` | 중형 지시 모델 (커뮤니티, upstream 런타임). 평가용 | `http://gemma-4-26b-predictor.kbl-models.svc:8080/v1` | 32768 | - | upstream | community | `vllm-upstream-0-28-0` | 2 |
| `qwen3-4b-instruct` | 범용 소형 지시 모델. 에이전트 tool calling, RAG 응답 생성 | `http://qwen3-4b-instruct-predictor.kbl-models.svc:8080/v1` | 32768 | hermes | ga | validated | `vllm-ga-3-2-4` | 1 |
