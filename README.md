# Remy

**A hands-free cooking coach that runs entirely on the phone, in airplane mode.** Gemma 4 E2B on LiteRT-LM is the judgment: it writes the recipe, looks at the counter, hears your answers and changes the recipe through function calling. LiteRT hand tracking is the reflex: a model-free loop that warns the moment a hand reaches a pot Gemma has boxed.

Runs on **iPhone 17** (LiteRT-LM Swift, Metal GPU) and **Pixel 10** (LiteRT-LM Kotlin, **Tensor G5 NPU, verified**). No cloud, no account, no API key.

Built at the Google Gemma Hardware Hackathon, AGI House, October 24, 2026.

[LiteRT-LM on iPhone: field report](docs/litert-on-iphone.md) · [Build and demo guide](docs/iphone-build.md) · [Pixel packaging](android/litertlm_package/INTEGRATION.md)

---

## What happens in the kitchen

1. **"Hey Remy, let's make a cold pasta salad."** Gemma writes the ingredient list and Remy reads it aloud and starts the camera. Once every ingredient is confirmed, Gemma writes the cooking steps for exactly that list and asks "Ready to cook?". A fixed pasta-salad preset exists in Settings for stage reliability; any other dish or any edited list is planned by Gemma.
2. **"Hey Remy, here's the cucumber."** The spoken name is only a hint. Gemma identifies the held food without being told, then confirms it on a closer crop before it counts.
3. **"I don't have red wine vinegar."** Remy suggests a substitute and calls `substitute_ingredient`; the list and the steps change on screen. "Let's just cook with what I have" removes what's missing.
4. **"Where's the salt?"** Gemma draws a box around it (`box_2d` on a 0–1000 grid).
5. **Reflexes.** Gemma names what on the counter could be hot and boxes it once. From then on, hand landmarks are checked against that box on every frame, with no model call, and the pill shows the time from frame to alarm. A knife is tracked with its own box while you cut.
6. **Hands full?** Thumbs up: next step. Thumbs down: back. Open palm: quiet.
7. **"How salty do you like it?"** Gemma hears the spoken answer directly as audio and saves it as a preference.
8. **See it think.** A drawer on the left edge shows Gemma's work live: what it heard, every tool call with its result and milliseconds, what the camera saw, and every reflex alarm. Evidence tallies the session: Gemma calls, tool calls, vision checks, boxes and audio.

## Two loops

| | Gemma loop (judgment) | Reflex loop |
|---|---|---|
| What | Plans, recognizes, grounds, converses, acts through tools | Checks hand geometry against zones Gemma boxed |
| Runs on | Gemma 4 E2B via LiteRT-LM (iPhone Metal GPU / Pixel Tensor NPU) | MediaPipe Tasks running LiteRT hand and gesture models, CPU |
| Speed | about a second per turn | every camera frame |
| Waits for the other? | no | **never**: the alarm doesn't call the language model |

**The model proposes, code decides.** Recipe state, pantry, finished steps and preferences live in app code: `RemyCore` (pure Swift, 101 tests) and its Kotlin port (97 JUnit tests). Gemma acts only through tools, and the app validates every call before anything changes.

## Gemma 4 E2B, used fully

- **Text:** writes the ingredient draft and the step graph as **structured JSON**, which the app validates; one corrective retry on bad output.
- **Vision:** identifies a held ingredient without being told the name, verifies it on a crop, looks at the board, names what could be hot.
- **Grounding:** `box_2d` boxes for hot things and requested items (we prompt with the Gemini `box_2d` convention; it works on E2B).
- **Audio:** hears the cook's spoken answers at "ask" steps as 16 kHz audio, with no separate speech recognizer.
- **Native function calling:** 16 tools, phase-gated so Gemma only sees the ones that make sense now. Automatic tool calling is off; results return as `tool` messages for a follow-up turn.
- **System instructions** with a prompt-injection guard: text seen in images or heard in audio is treated as untrusted scene content, never as instructions.
- **Two Gemma engines** on the iPhone, one dedicated to ingredient recognition so recipe writing doesn't block it.

## LiteRT and LiteRT-LM

**On the demo path**
- LiteRT-LM `Engine` + `Conversation` in Swift (0.18.1) and Kotlin (0.18.0), with `Tool` function calling and automatic tool calling off.
- Per-encoder backends: language model on the Metal GPU, vision and audio encoders on CPU (iPhone); `Backend.NPU` with CPU fallback (Pixel).
- `visualTokenBudget` (140 per image) and a per-model `cacheDir`, which brings a reload from 4.1 s to 0.9 s.
- `getBenchmarkInfo` for every number on the Evidence screen: prefill, decode, time to first token.
- MediaPipe Tasks running LiteRT models for hands and gestures, beside Gemma.
- On Pixel: Google's AOT-compiled Tensor bundle, packaged and verified with the `litert-google-tensor` agent skill.

**Evaluated, written up in the [field report](docs/litert-on-iphone.md)**
- Schema-constrained decoding (`ResponseFormat.json`); a Settings switch, off by default after a native abort on iPhone.
- Speculative decoding (MTP); never stops with a JSON schema, LiteRT-LM issue #3944.
- `Conversation.clone()` for prompt reuse, backported and benchmarked.
- GPU vision encoder on iPhone; fails to prepare in 0.18.1 (`STABLEHLO_COMPOSITE`).

## Measured

| Component | Device | Runtime / backend | Protocol | Result |
|---|---|---|---|---|
| Gemma 4 E2B recipe plan | iPhone 17, Release | LiteRT-LM 0.18.1; LM Metal GPU, vision/audio CPU | 855-token prefill, 355-token decode, single-call planner | 931 / 50.4 tok/s, first token 0.94 s, 8.0 s |
| Gemma tool turns | iPhone 17 | same | 5 scripted turns | 0.7–1.9 s each |
| Hands | iPhone 17 | MediaPipe Tasks (LiteRT models), CPU | 49.8 s live run | 29.8 fps, 12.9 ms median |
| Gemma 4 E2B load | Pixel 10, Tensor G5, Android 17 | LiteRT-LM 0.18.0, `Backend.NPU` | skill's `install_and_verify.py` | `"path":"npu"`, 4.3 s cold, under 1 s cached |
| Gemma hot-object look (image + text) | Pixel 10 | same | 484-token prompt with one image | first token 0.33–1.09 s, prefill 471–1,769 tok/s; box 2.05 s |
| Gemma ingredient draft | Pixel 10 | same | spoken "Remy, let's make pasta" → `plan_recipe` | 6.1 s |

## Limits

Gemma 4 E2B is a 2B-effective model: it can confuse look-alikes, can't count reliably, and may name things that aren't there when asked an open question. Remy is built around that: boxes as proof, the cook's word beats the camera, and alarms come from geometry, not the model. Remy has no temperature sensor; it warns about pots Gemma judged likely to be hot.

## Repo map

- `iOS/Remy/Sources/`: the iPhone app. `ChefAgent` (16 tools and the agent prompt), `ChefPrompt` / `ChefBrain` (every Gemma task), `GemmaRunner` (LiteRT-LM actor), `HandsFreeListener` + `AppleSpeech` (always-on mic), `CameraService` + `FastObjectDetector` (hands and object boxes), `AppModel` (state and the two loops), `RemyEval` (on-device eval harness).
- `RemyCore/`: pure Swift recipe contracts and validation, cooking session, hazard and knife watchers, voice commands and wake gate, box parsing. `swift test --package-path RemyCore`.
- `android/`: the Pixel app in Kotlin and Jetpack Compose, same layout as the iPhone. `TensorLmLoader` (from the skill), `RemyModel` (recipe, voice and agent flow), `agent/` (Gemma runner and the 16 tools), `core/` (RemyCore port, JUnit tests).
- `Vendor/`: pinned LiteRT-LM and MediaPipe Tasks packages with provenance (`UPSTREAM.json`).
- `scripts/`: model download with SHA-256 checks, device build, phone smoke test, simulator prompt eval.
- `docs/`: [build and demo guide](docs/iphone-build.md), [LiteRT field report](docs/litert-on-iphone.md), [team workflow](docs/team-workflow.md).

## Build

- **iPhone:** `python3 scripts/download_model.py`, then `cd iOS && xcodegen generate` and build the `Remy` scheme in Release. Put your team and bundle ID in `iOS/Local.xcconfig`.
- **Pixel:** `cd android && ./gradlew :app:assembleRelease`. Push the Tensor bundle for your phone's chip with `install_and_verify.py --litertlm-package android/litertlm_package` (see [INTEGRATION.md](android/litertlm_package/INTEGRATION.md)).

The 2.6 GB iPhone model and the 3.1–3.3 GB Tensor bundles are downloaded locally and stay out of Git.

## Team

- **Yunha Lee**
- **Tony Kim**

Remy grew out of the team repo we built during the hackathon; this repo is the cleaned-up iPhone and Pixel version.

## License

[MIT](LICENSE). Vendored packages in `Vendor/` keep their own licenses (Apache-2.0).
