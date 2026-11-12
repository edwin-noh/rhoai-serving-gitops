#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""AI팀 InferenceService 파일로 에이전트 개발자용 모델 카탈로그(Markdown)를 만든다.

사용법: uv run scripts/model-catalog.py [--check]
  --check   CATALOG.md 가 ISVC 파일과 맞는지만 확인 (다르면 종료 코드 1)

ISVC 파일이 유일한 원본이다. 모델을 추가/변경하면 같은 커밋에서 카탈로그를 다시 만든다.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

PROJECT_DIR = Path(__file__).resolve().parents[1]
MODELS_DIR = PROJECT_DIR / "ai" / "raw"
CATALOG_FILE = PROJECT_DIR / "ai" / "CATALOG.md"


def _arg(args: list[str], name: str) -> str | None:
    """vLLM 인자 목록에서 --name=value 또는 --name value 의 값을 찾는다."""
    for i, a in enumerate(args):
        if a.startswith(f"{name}="):
            return a.split("=", 1)[1]
        if a == name and i + 1 < len(args):
            return args[i + 1]
    return None


def model_row(isvc: dict) -> list[str]:
    meta = isvc["metadata"]
    name, ns = meta["name"], meta["namespace"]
    labels = meta.get("labels", {})
    annotations = meta.get("annotations", {})
    model = isvc["spec"]["predictor"]["model"]
    args = [str(a) for a in model.get("args", [])]
    gpu = model.get("resources", {}).get("limits", {}).get("nvidia.com/gpu", "-")

    parser = _arg(args, "--tool-call-parser")
    tools = parser if parser and "--enable-auto-tool-choice" in args else "-"
    return [
        # served-model-name 은 ISVC 이름 (ServingRuntime 의 --served-model-name={{.Name}})
        f"`{name}`",
        annotations.get("openshift.io/description", ""),
        f"`https://{name}-predictor.{ns}.svc:8443/v1` (토큰)",
        _arg(args, "--max-model-len") or "모델 기본값",
        tools,
        labels.get("kbl.io/runtime-tier", "-"),
        labels.get("kbl.io/model-source", "-"),
        f"`{model.get('runtime', '-')}`",
        str(gpu),
    ]


def render() -> str:
    rows = []
    for f in sorted(MODELS_DIR.glob("*.yaml")):
        for doc in yaml.safe_load_all(f.read_text(encoding="utf-8")):
            if doc and doc.get("kind") == "InferenceService":
                rows.append(model_row(doc))
    header = [
        "모델 (model)", "설명", "엔드포인트 (OpenAI 호환)", "최대 컨텍스트", "tool calling",
        "런타임 등급", "출처", "런타임", "GPU",
    ]  # fmt: skip
    lines = [
        "# 모델 카탈로그",
        "",
        "> 자동 생성 파일입니다. 직접 고치지 말고 `uv run scripts/model-catalog.py` 로 다시 만드세요.",
        "",
        "에이전트에서는 엔드포인트를 OpenAI 호환 `base_url` 로, 모델 이름을 `model` 로 씁니다.",
        "호출하려면 에이전트 네임스페이스에 `kbl.io/model-consumer=true` 라벨이 필요합니다 (Ops팀에 요청).",
        "런타임 등급 `upstream` 은 Red Hat 지원 대상이 아니고, `tool calling` 이 `-` 인 모델은 `tools` 요청을 처리하지 않습니다.",
        "",
        "| " + " | ".join(header) + " |",
        "|" + "---|" * len(header),
        *("| " + " | ".join(r) + " |" for r in rows),
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="모델 카탈로그(CATALOG.md) 생성")
    parser.add_argument("--check", action="store_true", help="CATALOG.md 가 최신인지만 확인")
    args = parser.parse_args(argv)

    content = render()
    if args.check:
        current = CATALOG_FILE.read_text(encoding="utf-8") if CATALOG_FILE.exists() else ""
        if current != content:
            print(f"{CATALOG_FILE} 가 ISVC 파일과 다릅니다. 다시 생성하세요.", file=sys.stderr)
            return 1
        return 0
    CATALOG_FILE.write_text(content, encoding="utf-8")
    print(f"작성: {CATALOG_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
