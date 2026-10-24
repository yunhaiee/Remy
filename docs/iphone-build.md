# iPhone implementation

This is the current implementation; the README describes what ships. Measurements marked historical come from the earlier build of this app (Oct 22–23).

## Actual stack

- SwiftUI, AVFoundation camera capture, and MediaPipe Gesture Recognizer (Tasks Vision **1.1.1**: the hand landmark model plus a gesture classifier) on the CPU so Gemma can retain the Metal GPU. Apple Vision hand detection has been removed.
- Gemma 4 E2B through LiteRT-LM **0.18.1**, with Metal for the language model and CPU for its image and audio encoders. CPU mode is available explicitly if Metal initialization fails. Apple SpeechAnalyzer (iOS 26) turns speech into text on device; Gemma hears answers to its own questions directly and transcribes only as a fallback.
- `Vendor/LiteRTLM` packages Google's v0.18.1 Swift wrapper (unmodified except a backported `Conversation.clone()`) and checksum-pinned official iOS binary. This avoids fetching the full upstream Git history and an unused macOS binary; provenance is recorded in `UPSTREAM.json`.
- `Vendor/MediaPipeTasks` selects the official checksum-pinned vision/common/graph binaries and preserves upstream graph registration link flags. The 8.4 MB float16 gesture recognizer bundle v1 is included for first-launch offline use; its source and SHA-256 are in `Resources/GestureRecognizer/gesture_recognizer.manifest.json`.
- Local recipe state, validated structured Gemma observations, a short in-memory image sequence, and a separate reach-warning path.
- No cloud inference, account, API key, or camera-upload service. Model setup downloads an exact, checksum-verified public artifact once. Camera images are not saved to Photos.

## Build and run

1. Install full Xcode and complete its first-launch prompts. Select the appropriate iOS components. Sign in to an existing Apple Account in Xcode Settings; a paid membership is not needed for personal device testing.
2. Connect and trust the iPhone. Enable Developer Mode and complete its restart. The Xcode version must support the phone's installed OS.
3. Install XcodeGen (`brew install xcodegen`). Run `xcodegen generate --spec iOS/project.yml` and open `iOS/Remy.xcodeproj`.
4. Signing: create `iOS/Local.xcconfig` (ignored by Git) with your own `DEVELOPMENT_TEAM = …` and, if the default app ID is taken, `PRODUCT_BUNDLE_IDENTIFIER = com.yourname.Remy`. Regenerating the project keeps these. Select the connected iPhone as the run destination, then build and run.
5. Tap the gear to open **Settings**. Download Gemma on Wi-Fi, or import the exact `.litertlm` file. The app verifies its size and SHA-256 before exposing Load Gemma.
6. Load Gemma. Turn on airplane mode and turn Wi-Fi off, then run the local text test. A new random marker must actually be generated; no canned response counts as a pass.
7. Start the camera, then use **Describe the live camera image**. Review the actual output against the visible scene. Export the inference receipt if needed.

Command-line alternatives:

```sh
python3 scripts/download_model.py
swift test --package-path RemyCore
REMY_TEAM_ID=YOUR_TEAM REMY_DEVICE_ID=YOUR_DEVICE zsh scripts/build_iphone.sh
REMY_DEVICE_ID=YOUR_DEVICE zsh scripts/phone_smoke.sh
```

Team and device identifiers are local configuration; do not commit credentials, private provisioning profiles, or device inventories. The model directory and build caches are ignored.

## Build, install, verify

```sh
python3 scripts/download_detector.py          # EfficientDet-Lite0 for the LiteRT detector, before every build
cd iOS && xcodegen generate -q
xcodebuild -project Remy.xcodeproj -scheme Remy -configuration Release -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates -derivedDataPath ../.dd build 2>&1 | grep -E "error:|BUILD"
xcrun devicectl device install app --device <UDID> ../.dd/Build/Products/Release-iphoneos/Remy.app
xcrun devicectl device process launch --console --device <UDID> <bundle id> -- --prompt-eval --short
```

The first install needs the model in the app's Documents: `REMY_DEVICE_ID=<UDID> REMY_BUNDLE_ID=<bundle id> zsh scripts/phone_smoke.sh` copies it and runs a text smoke test. `devicectl` error 4016 means the phone is locked. Never `git add -A` while `.dd/` exists.

## Demo flow (hands-free)

Stand the phone up sideways with the counter and both hands visible. Gemma loads at launch; the pill at the top shows Remy's line and the time of the last Gemma call.

Speech is for Remy when it starts with "Chef", "Hey Chef" or "Remy". A wake word alone opens eight seconds for the request. Once ingredients are confirmed and while cooking, conversation stays open without the wake word. Bare commands ("next", "go back", "say that again", "start cooking") act at once; everything else goes to Gemma, which answers in its own words and acts through tools.

1. "Hey Chef, let's make a cold pasta salad." With the demo preset off (default), Gemma writes the ingredient list. Show each ingredient: "Hey Chef, here's the cucumber."
2. "Chef, I don't have red wine vinegar." Remy suggests a swap and the drawer shows `substitute_ingredient`. "Let's just cook with what I have" shows `remove_ingredient`.
3. When every ingredient is confirmed, Gemma writes the steps and Remy asks "Ready to cook?" Say yes (or thumbs up).
4. "Chef, which knife should I use?" boxes the biggest knife (put one big and one small knife on the board).
5. Put an unheated pot in view. Gemma names and boxes it as a possible heat source; reach for it and the pill shows the orange "Reflex NN ms" alarm.
6. The ask step: "How salty do you like it?" Answer out loud; Gemma hears the audio and the drawer logs `save_preference`.
7. Open Settings → Session → Evidence: the session tally, the LiteRT-LM speed line, the LiteRT features used and the detector name.

Reset the recipe before each run (Settings → Session) so the tally and the plan start fresh. Rehearse three times in airplane mode with the preset off, then try Settings → Schema-constrained decoding on; keep it on only if a full run survives.

## Three-run rehearsal

**Setup, once.** iPhone 17 in airplane mode, Wi-Fi off, plugged in, sideways on a stand with the counter and both hands in view. Props: an unheated pot, cucumber, tomato, onion, a lemon, a box of pasta, salt, one big and one small knife. Open Remy and wait for the pill to show a Gemma time (warm-up done). Settings: Pasta-salad demo preset **off**, Schema-constrained decoding **off**, Core ML detector **off**, Fire safety · box & alerts **on**, Object boxes **on**, Hand gestures **on**. Open the drawer (sparkle in the dock) so the judges can see it.

**Each run** (about 3 minutes; say every line exactly):

1. Settings → Session → Reset recipe and memory. Evidence should read "This session: 0 Gemma calls · 0 tool calls · 0 vision checks · 0 boxes · 0 audio."
2. "Hey Chef, let's make a cold pasta salad." Drawer: Heard, then a Plan entry with its time. Remy reads Gemma's ingredient list aloud.
3. Hold each ingredient up: "Hey Chef, here's the cucumber." (one at a time). Drawer: a vision entry per item; Remy says "Got the cucumber."
4. For something on the list you did not bring: "Chef, I don't have red wine vinegar." Drawer: `substitute_ingredient`; the list changes. Then "Chef, let's just cook with what I have." Drawer: `remove_ingredient`.
5. When Remy asks "Ready to cook?": "Yes." Step 1 is spoken.
6. "Chef, which knife should I use?" Drawer: `find`; a box appears around the big knife.
7. Put the pot in view and keep talking quiet for ~15 s. Drawer: "Scanning for anything hot", then boxing; a dashed orange "Hot surface" box appears. Hold your whole hand flat over the pot so all of it is inside the box: the pill turns orange with "Reflex NN ms" and the drawer logs the reflex. (With the preset off this is the whole-hand rule; the one-second held alarm with vibration belongs to the pasta-salad preset's cooker steps.)
8. Thumbs up to move on. At "How salty do you like it?": "Not too salty, please." Drawer: Gemma heard the answer, or `save_preference`.
9. Open Settings → Session → Evidence: the tally line, the LiteRT-LM speed line, the LiteRT features list and "EfficientDet-Lite0 · LiteRT · CPU".

**Run 1 and Run 2** as above with constrained decoding off. Note any step that failed and the plan time in the drawer.
**Run 3**: Settings → Schema-constrained decoding **on** (takes effect on the next JSON call, no reload), then the same script. If the run completes with no crash and valid plans, keep it on for the demo; if the app stops or a JSON task fails, turn it off and reopen Remy.

**Historical measurements, previous single-call planner and runtime, Oct 23 (iPhone 17 Pro, Release, GPU):** plan about 11 s for a 5-step recipe (17–25 s for 9–12 steps) with ingredients after about 6 s; chef turns 0.5–0.8 s; ingredient check 2–3 s plus about 3 s to verify claims with boxes; a box search about 3 s; quick board check 1.3 s; a camera question 1.5–2 s; Gemma hearing an answer 1.1 s; Apple speech about 0.1 s after you stop (Gemma transcription fallback 0.35–0.6 s); hand tracking 30 fps at 19 ms per frame; warm-up about 4 s. That earlier configuration paused the camera during planning after concurrent GPU hand tracking slowed one plan to 108 s. The current ingredient-first flow keeps the preview running and uses CPU hand tracking; the split workflow and sustained concurrent performance still require physical measurement. The standard iPhone 17 has not been physically measured. The image encoder runs on CPU; LiteRT-LM 0.18.1 cannot build it on the iPhone GPU. The full LiteRT-LM findings are in [litert-on-iphone.md](litert-on-iphone.md).

## GoPro HERO12 Black

The optional input screen implements local GoPro HTTP control, UDP MPEG-TS reception, and native H.264 decoding into the same on-device Gemma pipeline. It checks the reported HERO12 model and shows separate packet and decoded-frame counters. Physical HERO12 Wi-Fi preview decoding has been verified on the iPhone; wired networking remains unsuccessful on this setup. GoPro documents preview video over UDP MPEG-TS and USB networking (NCM), not a standard AVFoundation webcam path. Do not claim that plugging a USB cable into an iPhone has established control, decoded frames, or working inference.

The current first test uses **USB cable** mode. Enter the last three digits of the camera serial; the app derives the documented `172.2a.1bc.51` address from suffix `abc`. This setting stays on the phone. USB HTTP and UDP use Network.framework with a required wired-Ethernet interface and Wi-Fi/cellular excluded. The app enables wired USB camera control and stops capture before requesting the webcam feed; it uses GoPro's default UDP MPEG-TS protocol rather than an unsupported protocol string. Wi-Fi is a separately selected fallback and is never chosen automatically.

For the cable swap: install while connected to the Mac, open **GoPro input**, verify **USB cable** and the serial suffix, then unplug the iPhone from the Mac and connect the powered HERO12 using a USB-C data cable. Keep the GoPro battery installed and stop recording. Tap **Connect wired GoPro**, allowing Local Network access if prompted. The screen separates the wired-interface result, HERO12 control response, received packets, and decoded frames. A connection log can be exported without saving video frames. No wired interface, successful control without packets, and packets without decoded frames are different failure stages; retain those diagnostics before changing transport.

The transport gate is: iPhone network interface appears → GoPro HTTP endpoint answers → preview packets arrive → H.264 frames decode → frames reach local Gemma. Local Wi-Fi can be an alternative camera link while inference remains on-device; enable the camera network through GoPro's setup and join it on the phone before connecting. Direct USB networking on this iPhone remains unverified. A moving egocentric camera also requires tracked object locations; a fixed screen-space salt zone cannot be treated as a stable physical location, so reach warnings are disabled in GoPro mode. GoPro documents approximately 210 ms minimum preview latency; do not claim a sub-150 ms end-to-end warning with this input. Use the phone camera when the demo needs the lowest input delay. GoPro latency must be assessed separately.

The demuxer and actual VideoToolbox decoder decoded 59 frames from a synthetic MPEG-TS stream on the Mac. This checks the decoding path, not GoPro transport, camera latency, or iPhone performance.

Physical connection checks on October 22: direct USB produced no wired interface, HTTP response, or video packets across four attempts. The Bluetooth/Wi-Fi fallback paired, read the camera network details, and enabled its AP using the published BLE command. The phone later ran approximately 100 seconds of real HERO12 Wi-Fi preview: 35,131 packets and 2,996 decoded frames before an intentional stop, with no saved error. A diagnostic app reinstall had interrupted an earlier feed; never install during a live GoPro test. GoPro tracking and Gemma on GoPro images require separate qualification.

For wireless setup, select **Wi-Fi** in GoPro input, find/select the camera over Bluetooth, and accept pairing on the phone. The app reads the SSID/passphrase and sends the AP enable request; these credentials stay in memory and are omitted from diagnostics. Join the camera network in iPhone Settings, then return and connect the preview. The camera network has no internet access. Verify a freshly installed developer build while the phone has normal internet access before changing to the GoPro network; do not reinstall during a live camera test. Bluetooth setup success does not by itself establish Wi-Fi association, HTTP reachability, or video decoding.

Reconnect handling now waits for pending stops, clears a previous Wi-Fi preview before starting, and retries HTTP 409 briefly while the camera settles. A three-second no-frame watchdog schedules at most three automatic reconnect attempts. Explicit Stop or leaving the app cancels recovery. A local HTTP keep-alive request runs every three seconds while streaming. Cancellation cannot replace the original startup error. UDP listener startup is bounded, and frame delivery to the main queue is bounded to prevent a backlog.

## MediaPipe fast loop

The live-stream task accepts at most one hand request at a time, plus one replaceable newest waiting frame. Newer frames replace older waiting inputs; there is no FIFO behind inference. Each result retains its exact image and monotonic capture/decoded-receipt timestamp; callbacks over 250 ms old cannot drive hand alerts. A generation token invalidates old permission callbacks, frames and results when changing sources or stopping. Phone preview uses the same RGB image as the landmarks. GoPro preview uses a separate native `AVSampleBufferDisplayLayer` fed directly by decoded pixel buffers, independent of MediaPipe and JPEG conversion. A display link requests a fixed 30 Hz and consumes at most two fresh decoded frames, marks each for immediate presentation, and skips enqueuing when the renderer is full. The small buffer smooths paired input arrivals, adds roughly one frame of buffering in that case, and discards inputs older than 90 ms; it cannot accumulate a long video queue. Overlay hand positions expire after 150 ms; GoPro reach alerts remain disabled. GoPro frames reach tracking on the decoder queue without a detour through the main UI. Connection counters update at most twice per second, and diagnostics refresh every five seconds. JPEG snapshots are compressed on a separate utility queue at most every 400 ms; Gemma keeps its existing JPEG contract. All images remain in memory.

Physical phone test on October 22: the user confirmed live finger landmarks. The phone recorded 1,488 processed frames in 49.81 seconds (29.87 fps), up to two hands, and 10.79 ms median / 11.74 ms p95 local processing across the latest 180 samples. These are capture/decoded-buffer receipt through matching landmarks and image preparation, **not sensor-to-screen latency**, a comparison against the old Vision loop, or an accuracy benchmark. Another actual image request completed in 2,770.39 ms with Gemma and MediaPipe both active; that is a coexistence smoke test, not image-understanding qualification or performance under sustained concurrent generation.

A first MediaPipe GoPro test did produce live video and landmarks, with 4,816 decoded frames, 57,781 packets and 51 acknowledged keep-alive requests before Stop. It also automatically reconnected once. However, tracking averaged only about 13-14 fps and the user reported visible lag. That result motivated the independent native preview and newest-frame handoff; do not report that first attempt as a satisfactory latency result. The native preview diagnostics separately report recent decoder/preview-enqueue fps and receipt-to-enqueue delay. These still do not measure sensor-to-screen latency. A first native-preview pass improved hand processing to about 21 fps but still presented about 14 fps despite 30 fps decoded input. Its display range permitted 15 Hz; a controlled simulator fixture then reproduced about 14.4 fps from paired frame arrivals even with 60 Hz display ticks. A two-frame buffer with fixed 30 Hz ticks displayed all 200 generated paired-input frames at 28.4 fps from a 28.6 fps measured source. Its recent receipt-to-enqueue p50/p95 was 32.3/61.3 ms, compared with 7.9/15.2 ms in the choppier latest-only synthetic pass. This is an explicit smoothing/delay tradeoff, not physical GoPro evidence. The native path records display ticks, decoder interarrival gaps, coalescing, backpressure and queue timing. Physical verification of this final pacing correction is pending.

`Documents/latest-hand-tracking.json` records sanitized counters, timing percentiles, backend and coarse brightness means, never frames. Keep the Mac phone viewer closed during physical camera tests. A black remote camera view was also seen in Apple's Camera app, while the user confirmed the physical camera and Remy worked directly on the phone. [Apple documents camera/microphone limitations in iPhone Mirroring](https://support.apple.com/en-us/120421).

Known upstream compatibility observation: the official MediaPipe graph archive and LiteRT-LM framework both register `ma_ios_notification_handler` from their audio dependencies. The system logs a duplicate Objective-C class warning. Camera inference and hand tracking completed in the same process before the latest AI-lane merge. Yunha's new spoken-answer flow now supplies WAV data to Gemma; that audio-input path has not been physically qualified alongside MediaPipe, and all consequences of the duplicate remain unqualified. No vendor binaries have been patched to hide it. Treat release qualification separately from these physical smoke checks.

Sources: [MediaPipe Hand Landmarker iOS](https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker/ios), [LiteRT-LM Swift](https://developers.google.com/edge/litert-lm/swift), [Open GoPro interfaces](https://gopro.github.io/OpenGoPro/), [GoPro stream/latency details](https://gopro.github.io/OpenGoPro/docs/faq/).

## Evidence and limits

Physical iPhone 17 Pro, October 22, 2026: a signed Release build launched, verified the complete Gemma artifact, initialized the Metal language-model backend, and generated an exact random marker. That one complete response took 455.66 ms; this is a single text smoke test, not a sustained benchmark. The receipt reported an available network path, so this does not establish airplane-mode operation or camera understanding. The raw response and hash were retrieved from the phone's app container.

The evidence screen distinguishes camera-derived observations, user confirmations, and system events. Receipts include the actual model response, model revision/hash, configured backend, elapsed time, image count, and network-path availability. Network-path availability is not proof of airplane mode or lack of cellular traffic. Timings are measured complete-response timings, not model-only benchmarks.

Core tests cover stale responses, salting provenance, moved camera, lost hands, approach direction, alert cooldown, invalid observations, and expired images. A successful build or unit test is not a physical iPhone inference result. Verify sustained behavior, voice output offline, thermal behavior, false warnings, and recovery on the phone before using public performance claims.

The final GoPro smoothing build was installed and launched on the physical iPhone after the phone returned to normal internet Wi-Fi. The user had confirmed the preceding native preview worked; the final two-frame pacing change still needs a separate physical performance check. The follow-up camera branch incorporates the latest merged AI lane from `main`; the integrated core suite has 24 passing tests.


### Current camera detector and memory setup

Run `python3 scripts/download_detector.py` before generating/building the project. The script fetches a pinned public EfficientDet-Lite0 model, verifies its size and SHA-256, and stores it in an ignored resource path. `scripts/build_iphone.sh` runs this step automatically. The detector is entirely local and never uploads camera data.

The app requests Increased Memory Limit. This capability was accepted by the current Personal Team profile on iPhone 17 Pro. Extended Virtual Addressing was rejected by that team and is not requested. Build in Release. GPU and CPU compiled caches are separated. Keep the app foreground for device checks; the active cooking screen disables auto-lock and restores it on background.

Fast object boxes expire after 0.5 seconds. COCO does not include cucumber, onion, tomato, or lemon, so produce predictions are displayed as **Produce**, and prepared-food predictions as **Food**, without guessing a replacement ingredient name. These labels cannot prove ingredient identity or temperature. Gemma handles semantic questions and explicit recipe checks separately. Turning **Settings → Object boxes** off hides ordinary boxes immediately; marked hot zones remain visible independently of that setting.
