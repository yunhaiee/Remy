# Two-person workflow

## One app, two lanes

The AI backend runs on the iPhone. This split does not add a web server or cloud inference service.

| Owner | Files and responsibility |
| --- | --- |
| Tony | `ContentView.swift`, `CameraService.swift`, `GoProSource.swift`, `H264PreviewDecoder.swift`, `AudioCoach.swift`: UI, phone/GoPro video, hand and future object tracking, overlays, fast alerts |
| Tony | `ReachTracker.swift`, `TransportStream.swift`, transport tests: visual reach logic and video transport |
| Yunha | `GemmaRunner.swift`, `ChefPrompt.swift`, `ModelStore.swift`, model manifest and downloader: local inference, runtime configuration, prompts, model setup |
| Yunha | `CookingSession.swift` and cooking-state tests: validated AI observations, recipe memory, legal state changes |
| Shared, coordinate first | `Contracts.swift`: geometry, recipe and observation data types. Any public API change consumed by the other lane |
| Tony integrates | `AppModel.swift`, `RemyApp.swift`, `iOS/project.yml`, app permissions, dependency packaging, build/install scripts: connect both lanes and test the shared iPhone |

Add new camera/tracking files in Tony's lane and new prompt/model helpers in Yunha's lane. Do not use a shared file as a dumping ground. Yunha can change the prompts without editing `AppModel.swift`. Coordinate changes to application lifecycle, model invocation signatures, or build dependencies first.

## Stable interface for this demo

Tony supplies up to three chronological JPEG frames plus the current `CookingSession`, frame count, and elapsed span. Frames stay in memory. Vision points use normalized coordinates: `(0,0)` is the image's top-left and `(1,1)` its bottom-right. Image fitting and overlays must use the same image rectangle. Gemma does not need to implement camera capture or draw UI.

Yunha keeps the callable `GemmaRunner.load(path:useGPU:)`, `GemmaRunner.run(prompt:images:structured:)`, and `ChefPrompt.make(session:frameCount:span:)` interfaces compatible. The runner returns actual text, elapsed milliseconds, and image count. Runtime errors remain errors; never substitute a canned response. Camera and GoPro acquisition must remain independent of model generation.

Structured observations contain exactly:

```json
{
  "confidence": 0.5,
  "saltAdded": false,
  "stepComplete": false,
  "concern": "uncertain",
  "evidence": "Example schema only; not a model result.",
  "line": "Please show me the bowl."
}
```

`concern` is `none`, `size`, `knife`, `visibility`, or `uncertain`. Confidence is an uncalibrated model output. A reach does not establish a pour. The app validates observations against the original session ID, state revision, image age, and number of frames; the AI runner must not mutate UI or salt guards directly. Adding object detections or tracked GoPro coordinates is a shared contract change: agree on labels, normalized boxes/points, timestamps, track identity, and validity before either lane depends on them.

## Branches and integration

Hackathon day: both work on `main` of `yunhaiee/Remy`, in small commits that each describe what they add. Pull before you start a change and push as soon as it builds. Coordinate before touching a shared file (`Contracts.swift`, `AppModel.swift`, `iOS/project.yml`) so two edits do not land on it at once.

Core changes run `swift test --package-path RemyCore`; app changes also get a signed Release build. Vision and model changes need a device check before the demo is called ready. Building the full iOS app requires a Mac with Xcode. Never `git add -A` while `.dd/` (local derived data) exists.

## Avoid project and asset conflicts

`iOS/project.yml` is the source of truth. Run `xcodegen generate --spec iOS/project.yml` to create your own ignored Xcode project. Signing teams and user state stay local. The large Gemma binary, build caches, private credentials, and device inventories stay out of Git. The small pinned MediaPipe hand task is deliberately bundled in Git so hand tracking works on first launch. The exact model revision, hash, and download URL live in the shared manifest.
