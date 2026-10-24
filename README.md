# Remy

A hands-free cooking coach that runs entirely on an iPhone in airplane mode. Gemma 4 E2B on LiteRT-LM is the judgment: it writes the recipe, looks at the counter, hears your answers and acts on the recipe through function calling. MediaPipe hand tracking on LiteRT is the reflex: a model-free loop that warns the moment a hand reaches a hot pot Gemma has boxed.

Built for the Google Gemma Hardware Hackathon (AGI House, Oct 24, 2026 · Mobile AI track, Best Use of LiteRT). No cloud, no account, no API key.

[한국어](#remy-한국어) · [LiteRT-LM on iPhone: field report](docs/litert-on-iphone.md) · [Build and demo guide](docs/iphone-build.md)

## What happens in the kitchen

1. **"Hey Chef, let's make a cold pasta salad."** Gemma writes the ingredient list, Remy says it out loud and starts the camera. Once every ingredient is confirmed, Gemma writes the cooking steps for exactly that list and Remy asks "Ready to cook?" (Settings has a fixed pasta-salad preset for rehearsals; it is off by default.)
2. **"Hey Chef, here's the onion."** The spoken name only asks for a look. Gemma identifies the held food without being told the name, then checks a closer crop or a matching printed label before the ingredient counts as present.
3. **Talk to it like a person.** "I don't have red wine vinegar." Remy suggests a substitute and calls `substitute_ingredient`, so the list and the steps change on screen. "Let's just cook with what I have" removes what is missing. It remembers what you lack.
4. **"Which knife should I use?" / "Where's the salt?"** A box appears around the right one, drawn from Gemma 4 `box_2d` grounding.
5. **Reflexes.** Gemma names what on the counter could be hot and boxes it. From then on the fast loop compares hand landmarks against that zone on every frame, with no model call, and the alarm shows its frame-to-alarm time.
6. **Hands full?** Thumbs up: next step. Thumbs down: back. Open palm: quiet.
7. **"How salty do you like it?"** Gemma hears your spoken answer from the audio itself and saves it as a preference.
8. **See it think.** A drawer on the left edge shows Gemma's work live: what it heard, each tool call with its timing and result, what the camera checks saw, and reflex alarms. Evidence (Settings → Session) tallies the session: Gemma calls, tool calls, vision checks, boxes and audio.

## How it runs

| Job | Model and LiteRT feature | iPhone 17, Release, Oct 24 (* = earlier build on iPhone 17 Pro, Oct 23) |
|---|---|---|
| Ingredients, then cooking steps | Gemma 4 text, JSON output contract, streaming preview | plan 8.0 s (prefill 931 tok/s, decode 50 tok/s, first token 0.94 s) |
| Conversation and actions | Gemma 4 function calling: 16 phase-gated `Tool`s, the app validates and runs each call, results return as `tool` messages | 0.7–1.9 s per turn |
| See the counter | Gemma 4 vision, 140 visual tokens per image | ingredient check 2–3 s* · look 1.5–2 s* |
| Box items, find hot things | Gemma 4 `box_2d` grounding (0–1000 grid) | ~3 s* |
| Hear the cook's answers | Gemma 4 native audio input (16 kHz WAV) | ~1.1 s* |
| Speech to text | Apple SpeechAnalyzer on device; Gemma transcribes if unavailable | ~0.1 s after you stop* |
| Hands and gestures | MediaPipe Gesture Recognizer on LiteRT, CPU | 29.8 fps · 12.9 ms median, 21 ms p95 |
| Object boxes | EfficientDet-Lite0 on LiteRT (MediaPipe Object Detector), CPU, 10 Hz | 9.7 ms median, 13 ms p95, beside the hand tracker |
| Hot-zone alarm | Fast loop on hand landmarks, no model call | within one frame |

**Three LiteRT models at once.** Gemma 4 E2B (LiteRT-LM, language model on the Metal GPU, vision and audio encoders on the CPU), the MediaPipe hand and gesture models, and EfficientDet-Lite0. A YOLOX-M Core ML detector can replace EfficientDet behind a Settings switch; it is off by default.

**Two loops.** Gemma is slow and smart: it plans, interprets the scene and talks. The hand loop is fast and dumb: it checks geometry against zones Gemma already boxed, so a warning never waits for the model.

**The app holds the state, not the model.** The recipe graph, pantry, finished steps, preferences and what the cook lacks live in `RemyCore`, a pure Swift package with 89 tests, and are saved to disk. Gemma decides through tools; the app validates every call before anything changes.

**LiteRT-LM features used:** `Tool` function calling with automatic tool calling off, `ResponseFormat.json` schema-constrained decoding (a Settings switch), `getBenchmarkInfo` for the prefill and decode speeds shown on Evidence, per-encoder backends (LM GPU, vision CPU, audio CPU), `visualTokenBudget`, `enableSpeculativeDecoding` (timing test), a per-model `cacheDir`, and a backported `Conversation.clone()`. What broke and what we measured is in the [field report](docs/litert-on-iphone.md).

## Honest limits

Gemma 4 E2B is a 2B model. It confuses look-alikes (a red bell pepper for a tomato), cannot count reliably, and names items that are not there when asked an open question. Remy is built around that: boxes as proof, knives found by size, the cook's word beats the camera, and alarms come from geometry, not the model. Step completion is suggested by Gemma and confirmed by the cook. Remy does not measure temperature or promise to prevent injuries.

## Repo map

- `iOS/Remy/Sources/` — the app. `ChefAgent` (16 tools and the agent prompt), `ChefPrompt` / `ChefBrain` (every Gemma task), `GemmaRunner` (LiteRT-LM actor and the session tally), `HandsFreeListener` + `AppleSpeech` (always-on mic), `CameraService` + `FastObjectDetector` (MediaPipe hands, EfficientDet), `AppModel` (state and the two loops), `RemyEval` (on-device eval harness).
- `RemyCore/` — pure Swift: recipe contracts and validation, cooking session, hazard and reach watchers, voice commands and wake gate, box parsing. `swift test --package-path RemyCore` runs in seconds.
- `Vendor/LiteRTLM`, `Vendor/MediaPipeTasks` — pinned packages (`UPSTREAM.json`; `Conversation.clone()` backport and a safe callback adapter).
- `scripts/` — model and detector download with SHA-256 checks, device build, phone smoke test, simulator prompt eval.
- `docs/` — [build and demo guide](docs/iphone-build.md), [LiteRT field report](docs/litert-on-iphone.md), [team workflow](docs/team-workflow.md).

Generate the Xcode project from `iOS/project.yml`. Signing and the 2.6 GB model stay local and out of Git.

---

# Remy (한국어)

비행기 모드의 iPhone 한 대에서 전부 돌아가는 핸즈프리 요리 코치입니다. LiteRT-LM 위의 Gemma 4 E2B가 판단을 맡습니다. 레시피를 쓰고, 조리대를 보고, 대답을 듣고, 함수 호출로 레시피를 직접 바꿉니다. LiteRT 위의 MediaPipe 손 추적은 반사신경입니다. Gemma가 박스로 표시한 뜨거운 냄비에 손이 닿는 순간, 모델 호출 없이 경고합니다.

Google Gemma 하드웨어 해커톤(AGI House, 2026년 10월 24일 · 모바일 AI 트랙, Best Use of LiteRT) 출품작입니다. 클라우드도, 계정도, API 키도 없습니다.

[English](#remy) · [iPhone에서의 LiteRT-LM 현장 보고서](docs/litert-on-iphone.md) · [빌드와 데모 안내](docs/iphone-build.md)

## 주방에서 일어나는 일

1. **"Hey Chef, 콜드 파스타 샐러드 만들자."** Gemma가 재료 목록을 쓰고, Remy가 소리 내어 말한 뒤 카메라를 켭니다. 재료가 모두 확인되면 Gemma가 그 목록에 맞춘 조리 단계를 쓰고, Remy가 "요리 시작할까요?"라고 묻습니다. (리허설용 고정 파스타 샐러드 프리셋이 설정에 있으며 기본값은 꺼짐입니다.)
2. **"Hey Chef, 여기 양파."** 말한 이름은 확인 요청일 뿐입니다. Gemma가 이름을 듣지 않은 채 들고 있는 음식을 알아보고, 더 가까운 크롭이나 일치하는 인쇄 라벨로 한 번 더 확인해야 재료가 '있음'이 됩니다.
3. **사람에게 말하듯 말하세요.** "레드 와인 식초가 없어." Remy가 대체 재료를 제안하고 `substitute_ingredient`를 호출해 화면의 목록과 단계가 바뀝니다. "있는 걸로 그냥 하자"라고 하면 없는 재료를 뺍니다. 없다고 한 재료는 기억합니다.
4. **"어떤 칼을 써야 해?" / "소금 어디 있어?"** Gemma 4 `box_2d` 그라운딩으로 맞는 물건 주위에 박스가 뜹니다.
5. **반사신경.** Gemma가 조리대에서 뜨거울 수 있는 것을 말하고 박스를 그립니다. 그 뒤로는 빠른 루프가 매 프레임 손 랜드마크를 그 구역과 비교하며 모델을 부르지 않고, 경보에는 프레임에서 경보까지의 시간이 표시됩니다.
6. **손이 바쁘면?** 엄지 위: 다음 단계. 엄지 아래: 뒤로. 손바닥: 조용히.
7. **"얼마나 짜게 좋아해요?"** Gemma가 오디오에서 직접 대답을 듣고 선호로 저장합니다.
8. **생각하는 모습을 봅니다.** 왼쪽 가장자리의 서랍이 Gemma의 작업을 실시간으로 보여 줍니다. 들은 말, 도구 호출마다의 시간과 결과, 카메라 확인이 본 것, 반사 경보. Evidence(설정 → Session)는 이번 세션의 Gemma 호출, 도구 호출, 비전 확인, 박스, 오디오 횟수를 셉니다.

## 어떻게 돌아가나

| 역할 | 모델과 LiteRT 기능 | iPhone 17, Release, 10월 24일 (* = 이전 빌드, iPhone 17 Pro, 10월 23일) |
|---|---|---|
| 재료, 그다음 조리 단계 | Gemma 4 텍스트, JSON 출력 계약, 스트리밍 미리보기 | 계획 8.0초(프리필 931 tok/s, 디코딩 50 tok/s, 첫 토큰 0.94초) |
| 대화와 행동 | Gemma 4 함수 호출: 단계별로 주어지는 `Tool` 16개, 앱이 호출마다 검증하고 실행, 결과는 `tool` 메시지로 회신 | 턴당 0.7–1.9초 |
| 조리대 보기 | Gemma 4 비전, 이미지당 시각 토큰 140개 | 재료 확인 2–3초* · 보기 1.5–2초* |
| 물건 박스, 뜨거운 것 찾기 | Gemma 4 `box_2d` 그라운딩(0–1000 격자) | 약 3초* |
| 요리사의 대답 듣기 | Gemma 4 네이티브 오디오 입력(16 kHz WAV) | 약 1.1초* |
| 음성을 글로 | Apple SpeechAnalyzer 온디바이스, 불가하면 Gemma가 받아씀 | 말이 끝나고 약 0.1초* |
| 손과 제스처 | LiteRT 위의 MediaPipe Gesture Recognizer, CPU | 29.8fps · 중앙값 12.9ms, p95 21ms |
| 물체 박스 | LiteRT 위의 EfficientDet-Lite0(MediaPipe Object Detector), CPU, 10Hz | 손 추적과 함께 중앙값 9.7ms, p95 13ms |
| 뜨거운 구역 경보 | 손 랜드마크 위의 빠른 루프, 모델 호출 없음 | 한 프레임 안에 |

**LiteRT 모델 세 개가 동시에.** Gemma 4 E2B(LiteRT-LM, 언어 모델은 Metal GPU, 비전·오디오 인코더는 CPU), MediaPipe 손·제스처 모델, EfficientDet-Lite0. 설정 스위치로 EfficientDet 대신 YOLOX-M Core ML 검출기를 쓸 수 있으며 기본값은 꺼짐입니다.

**두 개의 루프.** Gemma는 느리고 똑똑합니다. 계획하고, 장면을 해석하고, 대화합니다. 손 루프는 빠르고 단순합니다. Gemma가 이미 박스로 표시한 구역과 기하학만 비교하므로 경고가 모델을 기다리지 않습니다.

**상태는 모델이 아니라 앱이 들고 있습니다.** 레시피 그래프, 재료 현황, 끝난 단계, 선호, 없는 재료는 테스트 89개가 있는 순수 Swift 패키지 `RemyCore`에 있고 디스크에 저장됩니다. Gemma는 도구로 결정하고, 앱은 무엇이든 바뀌기 전에 모든 호출을 검증합니다.

**사용한 LiteRT-LM 기능:** 자동 도구 호출을 끈 `Tool` 함수 호출, `ResponseFormat.json` 스키마 제약 디코딩(설정 스위치), Evidence에 표시되는 프리필·디코딩 속도를 위한 `getBenchmarkInfo`, 인코더별 백엔드(LM GPU, 비전 CPU, 오디오 CPU), `visualTokenBudget`, `enableSpeculativeDecoding`(시간 측정용), 모델별 `cacheDir`, 백포트한 `Conversation.clone()`. 무엇이 깨졌고 무엇을 측정했는지는 [현장 보고서](docs/litert-on-iphone.md)에 있습니다.

## 솔직한 한계

Gemma 4 E2B는 2B 모델입니다. 비슷한 것을 헷갈리고(빨간 파프리카를 토마토로), 개수를 잘 못 세고, 열린 질문을 받으면 없는 물건을 말합니다. Remy는 그 전제로 만들었습니다. 증거로서의 박스, 크기로 찾는 칼, 카메라보다 늘 우선하는 사람의 말, 모델이 아니라 기하학에서 나오는 경보. 단계 완료는 Gemma가 제안하고 요리사가 확정합니다. Remy는 온도를 재지 않으며 부상 예방을 약속하지 않습니다.

## 저장소 안내

- `iOS/Remy/Sources/` — 앱. `ChefAgent`(도구 16개와 에이전트 프롬프트), `ChefPrompt` / `ChefBrain`(모든 Gemma 작업), `GemmaRunner`(LiteRT-LM 액터와 세션 집계), `HandsFreeListener` + `AppleSpeech`(상시 마이크), `CameraService` + `FastObjectDetector`(MediaPipe 손, EfficientDet), `AppModel`(상태와 두 루프), `RemyEval`(온디바이스 평가 도구).
- `RemyCore/` — 순수 Swift: 레시피 계약과 검증, 요리 세션, 위험·손뻗음 감시, 음성 명령과 호출어 게이트, 박스 파싱. `swift test --package-path RemyCore`가 몇 초면 끝납니다.
- `Vendor/LiteRTLM`, `Vendor/MediaPipeTasks` — 고정된 패키지(`UPSTREAM.json`, `Conversation.clone()` 백포트와 안전 콜백 어댑터).
- `scripts/` — SHA-256 확인이 있는 모델·검출기 다운로드, 기기 빌드, 폰 스모크 테스트, 시뮬레이터 프롬프트 평가.
- `docs/` — [빌드와 데모 안내](docs/iphone-build.md), [LiteRT 현장 보고서](docs/litert-on-iphone.md), [팀 작업 방식](docs/team-workflow.md).

Xcode 프로젝트는 `iOS/project.yml`로 생성합니다. 서명 설정과 2.6 GB 모델은 로컬에만 있고 Git에는 없습니다.
