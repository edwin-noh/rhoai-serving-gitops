# DGX B300 · MIG 프로파일 및 모델 할당

> **실제 프로파일 이름**(NVIDIA MIG User Guide B300 표): 이 문서의 `1g.31` = `1g.34gb`, `1g.63` = `1g.67gb`, `2g.63` = `2g.67gb`.
> 적용 절차: [ops/mig/mig적용방법.md](ops/mig/mig적용방법.md), GitOps 구성: `ops/mig/10-mig-config.yaml` (`kbl-dgx-b300-v1`)

> **자료 출처:** 사용자가 촬영한 화면 사진 3장(IMG_9268, IMG_9269, IMG_9270). 화면에 표시된 설계안을 문서화한 것으로, 실제 장비에서의 MIG 프로파일 지원 여부 및 배포 가능성을 검증한 결과는 아닙니다.

## 1. GPU 리소스 할당 개요

GPU별 MIG 구성과 모델 배치를 함께 표시한 운영 설계도입니다.

- **GPU 0–1:** OCR / Embedding 이중 구성. 두 GPU에 동일한 MIG 프로파일과 워크로드 배치를 적용하여 한쪽 GPU 변경 시 다른 GPU의 서비스 인스턴스를 유지하는 구성.
- **GPU 2–4:** AI Agent / RAG 동일 구성. 분산 및 예비 자원 확보.
- **GPU 5:** 유휴 / Scale-out buffer. MIG 프로파일은 구성하되 모델 미할당.
- **GPU 6–7:** No MIG. 전체 GPU 유휴.

## 2. GPU별 MIG 프로파일 배치

| GPU | 용도 | MIG 프로파일 및 개수 | 화면에 표시된 배치 |
|---|---|---|---|
| GPU 0 | AI OCR / RAG Embedding | `2g.63` × 1, `1g.31` × 4, `1g.63` × 1 | `2g.63`(OCR VLM), `1g.31`(Embedding/Reranker), `1g.31` × 2(OCR VLM), `1g.31`(미할당), `1g.63`(OCR worker) |
| GPU 1 | AI OCR / RAG Embedding | GPU 0과 동일 | GPU 0과 동일 |
| GPU 2 | AI Agent / RAG | `2g.63` × 3, `1g.63` × 1 | `2g.63` × 3(AI Agent), `1g.63`(RAG) |
| GPU 3 | AI Agent / RAG | GPU 2와 동일 | GPU 2와 동일 |
| GPU 4 | AI Agent / RAG | GPU 2와 동일 | GPU 2와 동일 |
| GPU 5 | 유휴 / Scale-out buffer | `2g.63` × 3, `1g.63` × 1 | 전체 미할당 |
| GPU 6 | 유휴 | No MIG | 전체 GPU 유휴 |
| GPU 7 | 유휴 | No MIG | 전체 GPU 유휴 |

> **주의:** 위 GPU 0–1의 색상별 모델 대응은 사진 속 범례 및 표를 종합하여 읽은 것입니다. 실제 MIG 인스턴스별 매핑은 원본 HTML 또는 클러스터 설정으로 확인하는 것이 좋습니다.

## 3. 모델별 할당 요약

원본 화면의 **‘모델별 할당 요약’** 표를 옮겼습니다. 표의 `replica`는 요청된 배치 수량 기준입니다.

| 워크로드 | GPU | MIG 할당 | MIG별 배치 | 전체 수량 / 비고 |
|---|---|---|---|---|
| AI OCR worker | GPU 0–1 | `1g.63` × 2 | 4 pods / MIG | 총 8 pods · time-slicing |
| RAG embedding / reranker | GPU 0–1 | `1g.31` × 2 | 8 / 4 vLLM replicas / MIG | embedding / reranker 순서 |
| AI OCR VLM1 | GPU 0–1 | `2g.63` × 2 | 1 replica / MIG | 총 2 replicas · Qwen3.8-27b *(모델명 판독 확인 필요)* |
| AI OCR VLM2 | GPU 0–1 | `1g.31` × 4 | 1 replica / MIG | 총 4 replicas · Qwen3-vl-8b *(모델명 판독 확인 필요)* |
| AI Agent | GPU 2–4 | `2g.63` × 9 | 1 replica / MIG | 총 9 replicas · Qwen3.8-27b *(모델명 판독 확인 필요)* |
| RAG | GPU 2–4 | `1g.63` × 3 | 1 replica / MIG | 총 3 replicas · Qwen3.8-27b *(모델명 판독 확인 필요)* |
| Scale-out buffer | GPU 0–1 | `1g.31` × 2 | 미할당 | GPU별 1개 |
| Scale-out buffer | GPU 5 | `2g.63` × 3 + `1g.63` × 1 | 미할당 | GPU 전체 유휴 |

### 수량 집계

- GPU 0–1: GPU별 MIG 인스턴스 6개, 합계 **12개**.
- GPU 2–4: GPU별 MIG 인스턴스 4개, 합계 **12개**.
- GPU 5: MIG 인스턴스 **4개**, 모델 미할당.
- GPU 6–7: **MIG 비활성화**, 전체 GPU 유휴.

## 4. 설계 해석 및 적용 전 확인사항

사진 하단의 안내 내용을 중심으로 정리했습니다.

1. **Embedding / reranker:** GPU 0/1에서 각각 `1g.31` 한 개를 공유하고, `8 / 4`는 embedding / reranker 순서의 MIG당 replica 수를 의미합니다. 두 서비스가 별도 MIG에 할당되는 방식으로 해석하지 않도록 주의합니다.
2. **MIG 프로파일:** 표시된 `2g` 카드는 `1g` 카드의 두 배 너비로 시각화된 것입니다. 이는 물리적 자원 구성이 아니라 **화면상 배치 표현**이므로, 실제 MIG slice 크기와 지원 조합은 별도 검증이 필요합니다.
3. **검증 범위:** 프로파일의 지원 여부, 실제 장비의 자원 프로파일, 조합별 배치 가능 여부, 모델 메모리 적합성을 검증한 결과는 아닙니다.
4. **고가용성:** GPU 0–1은 동일 프로파일/모델 배치를 통해 GPU 단위 변경 작업 시 다른 GPU의 인스턴스를 유지하려는 설계입니다.
5. **유휴 자원:** GPU 5는 scale-out buffer, GPU 6–7은 No MIG 전체 GPU 유휴로 표현되어 있습니다. 실제 유휴 용량은 트래픽 분산 및 운영 정책에 따라 달라집니다.
6. **Time-slicing:** AI OCR worker의 총 8 pods는 `1g.63` MIG 인스턴스 2개에 각각 4 pods를 배치하는 계획입니다. 이는 8개의 독립 MIG 인스턴스를 의미하지 않습니다.

## 5. 원본 사진

- IMG_9268.jpg — 제목, 설계 목적, GPU 0–2 배치
- IMG_9269.jpg — GPU 1–7 배치
- IMG_9270.jpg — 모델별 할당 요약 및 적용 전 확인사항

---

*사진 기반 전사 문서. 수치 및 모델명은 실제 배포 전 원본 HTML과 대조하십시오.*
