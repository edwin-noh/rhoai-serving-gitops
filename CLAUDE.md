# 프로젝트 지침

공통 지침(RHOAI 3.5 기준, 참고 문서 우선순위, 테스트 클러스터 정보)은 상위 `../CLAUDE.md` 를 따른다.

## 이 저장소
RHOAI 3.5 에서 LLM 을 KServe RawDeployment 와 llm-d + MaaS 두 방식으로 서빙하는 GitOps 매니페스트다.
- 클러스터 반영은 Argo CD 만 한다. 매니페스트 변경은 Git 으로 하고 `oc apply` 로 직접 반영하지 않는다.
- `ops/` 는 운영팀(ai-ops), `ai/` 는 AI팀 영역이다.
