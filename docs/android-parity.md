# Android (Pixel) parity with the iPhone build

Source of truth: `yunhaiee/yes-chef` branch `codex/iphone-stability` at `1d038b4` ("Load Remy's review portrait…").
iPhone paths below are relative to that repository (`Sources/` = `iOS/YesChef/Sources/`, `ChefCore/` = `ChefCore/Sources/ChefCore/`).
Android paths are relative to `android/app/src/main/java/com/yunha/remy/` on branch `android/parity`.

Status words:

- **Seen on Pixel**: the code exists and the behaviour was seen in a Pixel screenshot or in logcat.
- **Delivered, not yet seen**: the code exists and builds; what is needed to see it is in the note.
- **Not possible**: why, and what Android does instead.
- **Missing**: not on Android yet.

## Screen and controls

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| Landscape full-bleed camera, status bar and home indicator hidden | Sources/ContentView.swift:28-29, 239 | MainActivity.kt:124, ui/RemyScreen.kt:105 | Delivered, not yet seen (open the app) |
| Guidance pill: orb, Remy's line (17 sp white), Gemma time or "Reflex N ms", 600 dp max, tap opens Session | Sources/GlassControlDock.swift:206-254 | ui/RemyScreen.kt:277 | Delivered, not yet seen (open the app) |
| Pill priority through GuidancePillArbiter (knife 1 s notice, hot surface, reach alert, Remy speaking, curl hint, idle) | Sources/GlassControlDock.swift:472-513, ChefCore/GuidancePillArbiter.swift | ui/RemyScreen.kt:277-327, core/GuidancePillArbiter.kt | Delivered, not yet seen (needs a knife or hot-surface event while cooking) |
| Pill alert colour: red #E02020 for hot surface, orange #FFA552 for knife, 1.5 dp border | Sources/GlassControlDock.swift:244, 498 | ui/RemyScreen.kt:307-317 | Delivered, not yet seen (needs an alert) |
| Voice orb modes (off, listening, hearing, thinking, speaking, alert) with alert colour | Sources/GlassControlDock.swift:269-317 | ui/Glyphs.kt:53, ui/RemyScreen.kt:318 | Delivered, not yet seen |
| Left-hand curl panel under the pill ("Left hand · estimated curl", five fingers, %, orange below cutoff, dashes when unavailable) shown on step 2 or while readings exist | Sources/GlassControlDock.swift:450-469, Sources/ContentView.swift:68-71, Sources/AppModel.swift:339-341 | ui/RemyScreen.kt:120-121, 330 | Delivered, not yet seen (cooking, step 2) |
| Dock: video, microphone, sparkle (Gemma drawer); 43.5 dp circles in 54 dp targets | Sources/GlassControlDock.swift:6-75, 196-202 | ui/RemyScreen.kt:124-131, 158 | Delivered, not yet seen (same as the last port) |
| Primary action titles (Set up Remy, Loading Gemma…, Plan ingredients, Check ingredients, Start cooking, Open camera, Just say your answer, Answer out loud, Next step, Finish, All done) | Sources/ContentView.swift:428-471 | RemyModel.kt:196 | Delivered, not yet seen |
| Primary action disabled while no dish is typed | Sources/ContentView.swift:470 | RemyModel.kt:196 | Delivered, not yet seen |
| Session and Settings buttons, bottom right | Sources/GlassControlDock.swift:333-351, Sources/ContentView.swift:243-252 | ui/RemyScreen.kt:134-142 | Delivered, not yet seen |
| Gemma drawer: slim tab, 320 dp panel, "Gemma · live", hides "Chef says" and system rows, empty text "Say “Chef…” and the work shows up here as it happens." | Sources/AgentDrawer.swift:7-116 | ui/RemyScreen.kt:349 | Delivered, not yet seen |
| Planning: the camera dims to 45% black (no planning card in landscape) | Sources/ContentView.swift:212 | ui/RemyScreen.kt:109 | Delivered, not yet seen (plan a dish) |
| Status strip with NPU, TTFT, hands fps, thermal | none (Android only) | ui/RemyScreen.kt:408 | Android-only extra, kept for evidence |
| Portrait layout (header, camera card, chef line, flow card) | Sources/ContentView.swift:97-111, 254-287 | none | Not possible as a goal: the Pixel app is landscape only, as the iPhone is used on the counter; the same cards are in the Session sheet |

## Camera overlay

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| Hands: six chains, 1.5 pt lines, 2.5 pt joints, only frames under 0.2 s old | Sources/ContentView.swift:130-147 | ui/RemyScreen.kt:178, 198-224 | Delivered, not yet seen (cooking phase; hands are off while ingredients are checked, as on iPhone) |
| Estimated hands dashed and fading, "Estimating" under the wrist | Sources/ContentView.swift:132, 142, 148-152 | ui/RemyScreen.kt:205, 219-223 | Delivered, not yet seen (brief hand dropout while cooking) |
| Reach point ring at the index fingertip | Sources/ContentView.swift:153-154 | ui/RemyScreen.kt:224-226 | Delivered, not yet seen |
| Guard (salt) circle, fill 25%/10%, dashed | Sources/ContentView.swift:156-161 | ui/RemyScreen.kt:229-235 | Delivered, not yet seen (generated recipe with a guarded step) |
| Hot Surface box at 120%, dashed red, 22% fill while alerting, white "Hot Surface" tag on red, "Hot Surface · reacquiring" | Sources/ContentView.swift:162-176, Sources/AppModel.swift:212-213 | ui/RemyScreen.kt:237-246 | Delivered, not yet seen (cooking after step 1 with a pot, cup or bowl in view) |
| Knife box: dashed orange, 22% fill while alerting, "Knife" / "Knife · reacquiring" | Sources/ContentView.swift:177-190 | ui/RemyScreen.kt:247-254 | Delivered, not yet seen (cooking with a knife in view) |
| Object boxes: Gemma boxes plus fresh detector boxes, Produce/Food labels, no knife boxes while cooking | Sources/ContentView.swift:191-202, Sources/AppModel.swift:72-79 | ui/RemyScreen.kt:256-260, SafetyLoop.kt (visibleObjectBoxes) | Delivered, not yet seen (cooking with everyday objects in view) |
| "Tap the salt" prompt and tap-to-mark | Sources/ContentView.swift:205-210, 223-226 | ui/RemyScreen.kt:110-115, 189-197 | Delivered, not yet seen (guarded step, Mark salt) |

## Sheets

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| "Your session" sheet: headline (knife warning, curl hint, Remy's line), listening badge with heard words and Gemma time, status | Sources/ContentView.swift:34-40, 275-287, 474-492, Sources/AppModel.swift:346-350 | ui/SessionSheet.kt:53-66 | Delivered, not yet seen |
| Dish composer "Say it, or type a dish" with gradient send button | Sources/ContentView.swift:297-317 | ui/SessionSheet.kt:72-85 | Delivered (last port) |
| Plan preview "Writing the plan · N ingredients · N steps so far" | Sources/ContentView.swift:320-332 | ui/SessionSheet.kt (NEEDS_DISH) | Delivered (last port) |
| Ingredient checklist, "N of M ready", Have it / Missing / Check? / — / · you, tap to correct, Start cooking | Sources/ContentView.swift:334-366 | ui/SessionSheet.kt:91-118 | Delivered (last port) |
| Step card: Step N of M with gradient progress, title, instruction, Heads up, Tool, Not done yet, ask answer, Next step / Confirm step complete / Finish / Dish finished, You said | Sources/ContentView.swift:368-424 | ui/SessionSheet.kt:120-180 | Delivered (last port) |
| Guarded step: "Salt remembered · Gemma observed/you confirmed", "Mark where the salt is" / "Location marked by you…", Mark salt / Cancel marking, I added it / Allow more | Sources/ContentView.swift:399-412 | ui/SessionSheet.kt:155-170 | Delivered, not yet seen (generated recipe with salt) |
| Steps list sheet | Sources/ContentView.swift:41-56 | ui/SessionSheet.kt (tap the step bar: inline list) | Delivered as an inline list |
| Settings: Remy section (Hands-free voice, Watch the board automatically, Object boxes, Fire safety · box & alerts, Knife tracking · box & warning, Spoken responses, Short recipes, Pasta-salad demo preset, Hand gestures) with the iPhone's captions | Sources/ContentView.swift:640-671 | ui/SettingsSheet.kt:57-70 | Delivered, not yet seen (open Settings) |
| Settings: Camera picker iPhone / GoPro HERO12 | Sources/ContentView.swift:672-680 | ui/SettingsSheet.kt (Camera row) | Not possible: GoPro input needs the iPhone's Bluetooth/Wi-Fi/USB GoPro stack; Android shows "Pixel rear camera" and a 480p/720p hand-tracking choice |
| Settings: Look, Controls over the video (Dark glass / Light glass) | Sources/ContentView.swift:681-686, Sources/GlassControlDock.swift:96-129 | ui/SettingsSheet.kt:82-87, ui/Theme.kt (GlassStyle) | Delivered, not yet seen |
| Settings: Gemma section (Model, download/import, Metal GPU, Schema-constrained decoding, Running on, Load Gemma) | Sources/ContentView.swift:687-715 | ui/SettingsSheet.kt:89-94 | Partly not possible: the 3.1 GB Tensor bundle is sideloaded over adb (no in-app download or import), Metal is iPhone-only (Android runs on the Tensor NPU), constrained decoding is shown off and disabled (LiteRT-LM 0.18.0 Kotlin) |
| Settings: Session (Evidence, Run local text test with a random YES_CHEF_ marker, Describe the live camera image, Local test passed, raw reply, Reset recipe and memory with "Start a fresh session?") | Sources/ContentView.swift:717-735, Sources/AppModel.swift:595-619 | ui/SettingsSheet.kt:96-118, RemyModel.kt:938, 953 | Delivered, not yet seen |
| Evidence: Gemma, Last call speed, Image tokens, Structured output, Function calling 16 tools, Reflex latency, Audio in, Speculative decoding off, Fast vision, Network path, caveat | Sources/ContentView.swift:752-763 | ui/SettingsSheet.kt:129-149 | Delivered, not yet seen; Image tokens is honest that the Tensor bundle sets it |
| Evidence: "Left-hand finger curl guidance" toggle and caption | Sources/ContentView.swift:764-765 | ui/SettingsSheet.kt:151-152 | Delivered, not yet seen |
| Evidence: Session events (newest first, ORIGIN · time) and Last raw Gemma response | Sources/ContentView.swift:767-775 | ui/SettingsSheet.kt:169-179 | Delivered, not yet seen |
| Evidence: Export inference receipt | Sources/ContentView.swift:776, Sources/AppModel.swift:2212-2233 | none | Missing (no receipt file or share sheet on Android yet) |
| GoPro setup sheet | Sources/ContentView.swift:524-620 | none | Not possible: GoPro HERO12 control is iPhone-only (CoreBluetooth, iPhone USB networking) |
| Settings persist across launches | Sources/AppModel.swift:37-70, 316-318, 335-337 | MainActivity.kt:208 | Delivered, not yet seen |

## Finished dish review

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| "Ready" on the last step (DishReadySignal) or Next step there freezes the camera frame and opens the review | ChefCore/DishAssessment.swift:40-48, Sources/AppModel.swift:1472-1474, 2110-2111, 2244-2267 | core/DishAssessment.kt, RemyModel.kt:601, 535, 1127 | Delivered, not yet seen (finish the pasta salad's step 3) |
| Third preset step "Mix and finish" and migration of saved two-step sessions | ChefCore/IngredientDraft.swift:49-63, ChefCore/CookingSession.swift:86-106 | core/IngredientDraft.kt, core/CookingSession.kt (refreshPastaDemoSteps, reopenFinalDishReview) | Delivered (JUnit) |
| Two Gemma calls with the iPhone's prompts: photo observations, then Remy's rating grounded in them; one validation retry; no invented rating | Sources/AppModel.swift:2272-2344 | RemyModel.kt:1149, 1241, 1252 | Delivered, not yet seen |
| Full-screen summary, landscape: name and photo (30%), Remy portrait 56 dp, "Remy's Rating", stars with halves and "N.N / 5", summary, four sections | Sources/ContentView.swift:784-899 | ui/DishReview.kt:56, 109-170 | Delivered, not yet seen |
| Remy portrait asset | Resources/ReviewAssets.xcassets/RemyPortrait.imageset/remy.png | res/drawable-nodpi/remy_portrait.png (512 px copy) | Delivered, not yet seen |
| "Examining the photo…", error line, Retry review, Retake photo, Screenshot, Next dish | Sources/ContentView.swift:798-811 | ui/DishReview.kt:68-83 | Delivered, not yet seen |
| Screenshot saved to Photos, "Dish summary" alert | Sources/ContentView.swift:815-837 | ui/DishReview.kt:74-79, MainActivity.kt:334 | Delivered, not yet seen (saves the summary area to Pictures/Remy) |
| Summary survives a relaunch | Sources/AppModel.swift:2362-2382 | RemyModel.kt:1225 | Delivered, not yet seen |

## Safety rules and the fast loop

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| Hot-surface window: from confirming step 1 until the dish is complete, for every recipe | ChefCore/CookingSession.swift (cookerSafetyArmed), Sources/AppModel.swift:309-311 | core/CookingSession.kt, SafetyLoop.kt (hotWatchEnabled) | Delivered (JUnit), not yet seen |
| 120% expanded boundary used for both drawing and checking | ChefCore/HazardWatch.swift:26-34, Sources/AppModel.swift:2052-2063 | core/HazardWatch.kt (expanded), SafetyLoop.kt:299 | Delivered (JUnit), not yet seen |
| Immediate overlap (no dwell), any landmark or finger segment, held until exit, no re-entry cooldown | Sources/AppModel.swift:2052-2071 | SafetyLoop.kt:293-301 | Delivered (JUnit), not yet seen |
| Held warning: speech "Be careful of the pot on the stove!" once per entry, continuous vibration until clear, watchdog clears after 0.3 s without frames | Sources/AppModel.swift:208, 214-255, Sources/AudioCoach.swift:104-160 | SafetyLoop.kt:369-421 | Delivered, not yet seen |
| Step 1 pre-location of the cooker without showing or arming it | Sources/AppModel.swift:279-292 | RemyModel.kt:1088 | Delivered, not yet seen |
| Hot scan: preset boxes pot/pan/cooker/kettle/cup/bowl; other recipes name hot things then box them; retried every 5 s / 15 s while nothing is watched and it is quiet | Sources/AppModel.swift:1851-1911, 2077-2082 | RemyModel.kt:988, 1017, 1051 | Delivered, not yet seen |
| Cup and bowl detector boxes seed hot boxes directly | Sources/AppModel.swift:293-308 | SafetyLoop.kt:168 | Delivered, not yet seen |
| Hot things in a look or glance become watched | Sources/AppModel.swift:1303, 1784, 1842-1846 | RemyModel.kt:869, 1078 | Delivered, not yet seen |
| Tracking the hot box between Gemma looks (Apple Vision) | Sources/CameraService.swift:92-164 | SafetyLoop.kt:181 | Not possible: Apple Vision object tracking does not exist on Android. Detector-seeded cup/bowl boxes are re-detected at 10 Hz and shown as reacquiring when lost; Gemma-located pot boxes stay where Gemma put them until the camera moves |
| Cooker power voice commands ("I turned the cooker on/off", "the kettle is on") with the iPhone's replies | ChefCore/HazardWatch.swift:182-201, Sources/AppModel.swift:1459-1471 | core/HazardWatch.kt (CookerPowerCommand), RemyModel.kt:586-600 | Delivered (JUnit), not yet seen |
| Knife box seeded from detector boxes (strong hit at once, weak hit after three agreeing frames), re-detection keeps the same knife | ChefCore/KnifeTracking.swift:3-61, Sources/AppModel.swift:518-525, Sources/CameraService.swift:191-232 | core/KnifeTracking.kt, SafetyLoop.kt:203, 220 | Delivered (JUnit), not yet seen |
| Knife box seeded by Gemma ("which knife?") | Sources/AppModel.swift:1805-1806 | RemyModel.kt:897, SafetyLoop.kt:212 | Delivered, not yet seen |
| Knife tracking between detections (Apple Vision) | Sources/CameraService.swift:233-264 | SafetyLoop.kt:230 | Not possible: no Vision tracker. Android re-detects at 10 Hz: healthy for 0.45 s after the last detection, "reacquiring" for one more second (no alarm), then gone; a Gemma-grounded box stays 10 s |
| Knife rule: only one confident left hand; a finger warns only if it overlaps the box and is below its curl cutoff (thumb 10%, others 25%); palm alone does not | ChefCore/KnifeTracking.swift:63-138, Sources/AppModel.swift:2033-2048 | core/KnifeTracking.kt, SafetyLoop.kt:283-291 | Delivered (JUnit), not yet seen |
| Knife alarm: silent, held vibration, one-second re-trigger cooldown, drawer row "Left hand is near the knife", watchdog after 0.25 s | Sources/AppModel.swift:85-142 | SafetyLoop.kt:348-367, 405 | Delivered, not yet seen |
| Finger flexion from 3D world landmarks with smoothing and the 0.12 s persistence hint | ChefCore/FingerFlexion.swift, Sources/AppModel.swift:351-374 | core/FingerFlexion.kt, SafetyLoop.kt:328 | Delivered (JUnit), not yet seen |
| Hand continuity: display-only smoothing and up to 0.2 s coasting, never used for safety | ChefCore/HandContinuity.swift, Sources/CameraService.swift:686-695 | core/HandContinuity.kt, SafetyLoop.kt:242-247 | Delivered (JUnit), not yet seen |
| Reach / salt warning: approach of the marked salt after it was added, "Already added salt. Taste it first!", beep and haptic | ChefCore/ReachTracker.swift, Sources/AppModel.swift:1999-2019, Sources/AudioCoach.swift:81-93 | core/DishAssessment.kt (ReachTracker), SafetyLoop.kt:262-268, 306, 320 | Delivered (JUnit), not yet seen |
| Gemma marks the salt automatically on a guarded step | Sources/AppModel.swift:1826-1839 | RemyModel.kt:1103 | Delivered, not yet seen |
| Gesture hold rules: thumbs up 1 s, thumbs down 0.6 s, open palm; one command per hold, 2.5 s quiet; only uniquely identified fresh hands; never during an alert or hot contact | ChefCore/GestureHoldWatch.swift, Sources/AppModel.swift:2020-2031, 2089-2103 | core/GestureHoldWatch.kt, SafetyLoop.kt:274-279, RemyModel.kt:967 | Delivered (JUnit), not yet seen |
| No hand or object inference while ingredients are checked | Sources/CameraService.swift:265-272, 597 | MainActivity.kt:365, 441 | Delivered, not yet seen |
| Camera moved (device rotation over 0.14 rad): clears boxes, hot boxes, the salt mark | Sources/CameraService.swift:528-543, Sources/AppModel.swift:536-543 | MainActivity.kt:241, RemyModel.kt:1004 | Delivered, not yet seen (game rotation vector instead of CoreMotion) |
| EfficientDet-Lite0 int8 object detector, one request in flight, 10 Hz (5 Hz when hot) | Sources/FastObjectDetector.swift | MainActivity.kt:377 | Delivered, not yet seen (logcat REMY_DETECTOR) |
| YOLOX-M Core ML detector | Sources/CoreMLKitchenDetector.swift | none | Not possible: Core ML is iPhone-only. Android uses MediaPipe EfficientDet-Lite0, the iPhone's own fallback, with the YOLOX path's thresholds (boxes 0.5, knife candidates 0.25) |
| Build fails loudly without the detector model | scripts/download_detector.py | app/build.gradle.kts | Delivered (build checks size 4602795 bytes) |

## Voice, Gemma tasks and tools

| Component | iPhone (file:line) | Android (file:line) | Status |
|---|---|---|---|
| Wake words "Remy" / "Hey Remy", conversation open while cooking | ChefCore/ChefWakeGate.swift:4-23 | core/ChefWakeGate.kt:7 | Delivered (last port) |
| Ready-to-cook replies, step completion by "ready" | ChefCore/ChefWakeGate.swift:24-, Sources/AppModel.swift:1475-1489 | core/ChefWakeGate.kt:34, RemyModel.kt (handleWords) | Delivered (last port) |
| Ingredient cue ("here's the onion") and spoken confirmations inside the agent branch | Sources/AppModel.swift:1490-1520 | RemyModel.kt:616, 635 | Delivered, not yet seen |
| Voice commands (next, back, repeat, start cooking, wake) | ChefCore/VoiceCommand.swift | core/VoiceCommand.kt | Delivered (last port) |
| Speech recognition | Sources/AppleSpeech.swift, Sources/HandsFreeListener.swift | VoiceListener.kt:32 | Not possible as Apple Speech; Android uses its on-device SpeechRecognizer (ends utterances from partial results) and Gemma audio for answers |
| Speech hints (dish and ingredient names) | Sources/AppModel.swift:1561-1566 | none | Missing (Android 13 biasing strings not wired; VoiceListener left unchanged) |
| Wake preview on a second engine (start recognition as "Remy" is heard) | Sources/AppModel.swift:1530-1559, 1061-1079 | none | Not possible on this Pixel: a second 3.1 GB Gemma engine does not fit next to the first; Android runs one engine |
| Push-to-talk answers when hands-free is off ("Answer out loud", MicButton) | Sources/ContentView.swift:494-522, Sources/AppModel.swift:1344-1382 | ui/SessionSheet.kt:188 (typed answer only) | Missing (typed answers and hands-free audio answers work) |
| Spoken lines, "Thinking." on ingredient checks, "One moment." | Sources/AudioCoach.swift:55-79 | Speaker.kt:11, RemyModel.kt:466 | Delivered, not yet seen |
| Persona and every prompt verbatim with Remy naming (plan, ingredient draft, instructions, presented ingredient, verify, ingredients, board, glance, look, hazards, locate, transcribe, answer, question) | Sources/ChefPrompt.swift:15-430 | core/ChefPrompt.kt:21-426 | Delivered (literal comparison script: all 247 literals present except escape-only differences) |
| Dish review prompts | Sources/AppModel.swift:2295-2320 | RemyModel.kt:1241-1270 | Delivered |
| Presented ingredient: blind identity, then package-label OCR inside the box, else a closer crop; iPhone's reply lines | Sources/ChefBrain.swift:34-98, Sources/AppModel.swift:1122-1223 | RemyModel.kt:375, 439 | Delivered, not yet seen |
| Package-label OCR | Sources/ChefBrain.swift:69-88 (Vision text recognition) | MainActivity.kt:316 | Delivered, not yet seen: ML Kit text recognition with its bundled Latin model, on the phone, no network |
| Board check and glance with one corrective retry; quiet automatic glance every 6 s | Sources/ChefBrain.swift:232-253, Sources/AppModel.swift:1285-1331, 2083-2086 | RemyModel.kt:805, 988 | Delivered, not yet seen |
| 16-tool agent with follow-up turn | Sources/ChefAgent.swift:8-339 | agent/ChefAgent.kt:73, 297 | Delivered (last port) |
| Tools: hot_object, find, look, check_ingredients use the new paths | Sources/AppModel.swift:1671-1722 | RemyModel.kt (execute) | Delivered, not yet seen |
| Warm-up call after loading | Sources/AppModel.swift:582-593 | RemyModel.kt:128 | Delivered, not yet seen (logcat REMY_WARMUP) |
| Local text test with random marker; camera description prompt | Sources/AppModel.swift:595-619 | RemyModel.kt:938, 953 | Delivered, not yet seen |

## Not ported on purpose

Device regressions and diagnostics receipts (stabilitySmoke, ingredientFirstSmoke, capture-health and detector-performance JSON, GemmaEval), speculative decoding (DEBUG only on iPhone), GoPro.
