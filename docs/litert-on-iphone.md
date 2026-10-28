# Gemma 4 + LiteRT-LM on iPhone: what we built and what we learned

Current image-path qualification: every image call uses the same 140-token encoder signature. The variable-token `--vision-bench` and `--box-tokens` flags are disabled in this stability build; their historical results below do not describe the current fixed-signature path.

Runtime stability note: these measurements describe the earlier constrained-decoding path. The app now keeps schemas in prompts and validates responses in Swift because the pinned native llguidance tokenizer aborted on iPhone. Image calls use a fixed 140-token signature after allocation failures in object localization and later image checks. Remeasure accuracy/detail and timings for this path.


**Setup:** Gemma 4 E2B (`.litertlm`, 2.6 GB) on an iPhone 17 through LiteRT-LM 0.18.1 (Swift). Language model on the Metal GPU; vision and audio encoders on the CPU. 100% on device, works in airplane mode.

### What Gemma does in Remy

| Job | LiteRT-LM feature | iPhone 17 |
|---|---|---|
| Plan a recipe from one sentence | Constrained decoding (JSON schema), streaming to the screen | 11 s (5 steps); ingredients appear while it writes |
| Talk and act as the chef | Function calling, 16 tools, app-executed; tool results sent back as `tool` messages | 0.5–0.8 s per turn |
| See the counter | Multimodal image input, per-task visual token budgets (70 / 140 / 280) | glance 1.3 s, full check 3.4 s |
| Box items, find hot pots | Gemma 4 `box_2d` grounding (0–1000 grid) | ~3 s |
| Hear the cook's answers | Native audio input (16 kHz) | ~1.3 s |

A second, model-free loop (MediaPipe hand tracking, ~29 fps) uses Gemma's boxes to warn instantly when a hand reaches a hot pot or reaches for the salt twice.

### What E2B vision can and cannot do (measured on photos)

- **Good:** naming everyday items, reading labels, boxing a named item (knife, cucumber, tomato, bananas, cleaver, bread knife), size and position words ("the smallest knife", "the largest knife at the bottom").
- **Hot things, asked conservatively ("what is or may be hot, cookware and appliances even if off"):** a rice cooker photo → "kettle, electric cooker", both boxed correctly; an electric kettle, a hot plate and stove pots all named and boxed (1.2–2 s to name, ~3–4 s to box). On a plain vegetable board it also listed "knife", so names are filtered to heat words before they become hot zones.
- **Weak:** knife types by name (paring, chef's, serrated picked the wrong knife), counting (5 knives → 4, 6 → 4, 5 lemons → 4; boxing "all the knives" returned nothing), look-alikes (red bell pepper → tomato, zucchini → cucumber), and inventing items on an empty frame when asked what it sees. The app asks for knives by size and accepts an ingredient only if Gemma can also box it.

### Findings worth sharing with the LiteRT team

1. **Vision encoder on the iPhone GPU fails** in 0.18.1 (`STABLEHLO_COMPOSITE failed to prepare`), so images are encoded on the CPU. The simulator's Metal path fails too (`texture argument index 31`).
2. **Speculative decoding (MTP) works per conversation, but not with a JSON schema.** With constrained decoding the output never stops: it ran to the token limit, and with a larger limit the drafter crashed past the context (98.7% of drafts accepted). Written free-form and parsed leniently, the plan went from 18.9 s to 13.9 s (decode 26.6 → 44.9 tok/s, CPU simulator). On the iPhone GPU, though, one speculative conversation broke every later schema or image call with a native executor error until relaunch, even with speculation explicitly off for those conversations, so it is off in the app.
3. **The upstream Swift streaming wrapper always executes tools,** even with `automaticToolCalling: false`. The app now uses a local `sendMessageSafely` adapter over the native asynchronous API. It aggregates text/channel deltas and tool-only replies without executing tools; the app validates and executes permitted actions.
4. **Loosely written tool calls** (`call:save_preference{value:mild}`) make the parser throw; we recover the intended call from the error text.
5. **A tight `maxItems` in the schema stalled planning about 100 s** (the model fights the cap until the token limit). The step limit now lives in the prompt: 11 s.
6. **Benchmark info needs `optIntoExperimentalAPIs()`;** without it the speeds silently stay empty.
7. **GPU contention:** planning while the camera and hand tracking ran took 108 s; pausing the camera brought it to 17–25 s.

### Measured on the Remy build (iPhone 17, Release, Oct 24)

Read from LiteRT-LM's own `getBenchmarkInfo` and the app's receipts, not typed by hand.

- Engine load 4.1 s cold (Metal GPU, vision and audio on CPU), 0.9 s once the compiled cache exists.
- Recipe plan for "cold pasta salad": 8.0 s end to end; prefill 855 tokens at 931 tok/s, decode 355 tokens at 50.4 tok/s, first token 0.94 s. The same prompt on the CPU simulator: 18.6 s (362 / 18.3 tok/s).
- Function calling, five scripted turns: `substitute_ingredient`, `check_ingredients`, two `remove_ingredient`, `save_preference`, `mark_added`, each 0.7–1.9 s.
- MediaPipe hands on CPU with EfficientDet-Lite0 at 10 Hz beside it: 29.8 fps, 12.9 ms median / 21.4 ms p95 per frame; the detector 9.7 ms median / 13.3 ms p95.
- Backgrounding stalls everything: launched while the phone was dark, the app went to the background and the Metal engine never finished its first call. Keep Remy in front during evals.

## Native callback lifetime correction

A later physical iPhone regression crashed in the native asynchronous callback while another thread destroyed its conversation. The pinned synchronous send can leave callbacks pending after a wait error; immediate teardown or an engine rebuild is unsafe in that state. The app now uses the asynchronous C entry point with explicit ownership through completion. Successful cleanup happens off the native callback thread. Any native error, malformed payload or 120-second callback timeout retains every affected conversation and engine (at most two admitted engines) until process exit and refuses further inference. The UI asks the user to reopen the app; it does not retry or cancel potentially live native work. The official native binary is unchanged.

The timeout bounds a callback wait after native startup returns; it cannot interrupt a native startup function that itself never returns. Local lifecycle tests use the real message parser and production callback state with a stub native owner. They exercise empty deltas, tool-only replies, startup/final ordering, errors, timeouts and late callbacks. Physical device testing remains required for the complete runtime.


## Camera-led ingredient recognition

The main view announces ingredients and automatically enables the selected camera. The manual checklist appears in Session; instruction preparation has no progress message or automatic sheet. Speech such as "here is the onion" requests an image check and is not evidence of presence. A blind visual identity must agree with either a closer crop or independent on-device OCR of a matching product label inside its box before marking an ingredient seen. Exact short product labels reject recipe sentences, salt-free claims and pepper. Specific pasta shapes map to pasta; a salt shaker/grinder needs readable packaging or visible crystals. COCO labels are never fed into this path.

Recipe generation and ingredient recognition use independent Gemma 4 E2B Metal engines, with CPU image encoders and fixed 140-token image signatures. The callback lifetime guard admits one request per engine, at most two in total; any uncertain native failure blocks all further admission until restart. It retains both owners if both fail. No native binary was changed.

On one iPhone 17 Pro, three blank-image negative checks running alongside valid recipe drafts took 2.38, 2.55 and 2.59 seconds on E2B Metal, versus 10.90, 10.87 and 10.92 seconds on E4B CPU. All returned unknown and confirmed no ingredient. These are one-pass negative compatibility/timing probes, not real ingredient accuracy or full two-pass latency. E4B CPU is not the automatic recognition path because its response latency is unsuitable here. No physical standard iPhone 17 result is available.

The faster package path reads text from the captured still concurrently with Gemma's first image pass. It skips the second generative call only when their identities agree and the label lies inside Gemma's food box. Other foods retain the close-crop call. Both prompts request concise visual evidence; automatic rechecks back off from 4 to 12 seconds during serious/critical thermal pressure, while explicit spoken checks bypass that automatic delay. These changes require fresh packaged-food timing and accuracy measurements.


## Wake-gated ingredient focus

Voice actions require a finalized Hey Chef prefix, or the single eight-second continuation opened by a finalized wake-only utterance. Recent chef speech never opens the gate. Unaddressed words are discarded before command execution, transcript UI, conversation logging or Gemma input. On-device Apple Speech uses volatile results to start a bounded, silent visual preview before the utterance ends; tentative text cannot change pantry state. See [Apple's reporting options](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption).

Ingredient requests play capture feedback and say Thinking. A matching current preview is consumed once; otherwise a fresh still is analyzed. Source, session, semantic epoch and age checks reject stale previews. Native inference is never cancelled or torn down to replace a preview. Recognition health separates model elapsed time from request-to-result time and records whether a preview was reused.

The ingredient stage bypasses MediaPipe and generic object detection while preserving full-detail video and JPEG snapshots. Timer-driven ingredient recognition and all hot-object searches, including vessel fallback boxing, are disabled in that stage. Recipe instruction work waits until ingredient collection is complete or the cook explicitly asks to start. Cooking restores the normal hand/object pipelines. No new hardware latency result is claimed until this version runs on the physical phone.


## Cooking handoff and open conversation

Chef and Hey Chef both open ingredient requests. Once the ingredient list is fully confirmed, the app asks Ready to cook and accepts natural affirmative/negative replies without requiring another wake phrase. A pending start waits for executable instructions; a negative reply clears that pending intent. Cooking mode keeps voice conversation open. Whole done/next/back/repeat commands act immediately; other speech goes to local Gemma with recipe context. Final completion stops automatic board reviews and announces the dish is ready instead of repeating the final step.

A physical run exposed an unusable instruction reply: the model appended a seasoning ask step with missing fields and null values, despite the fixed salt-free list. The exact unedited five-ingredient pasta salad now has a validated three-step app recipe preset. This is not reported as generated inference. Other dishes/edits retain model generation. Tests cover the five-item readiness transition, queued instruction handoff, natural replies, step navigation and completion.
