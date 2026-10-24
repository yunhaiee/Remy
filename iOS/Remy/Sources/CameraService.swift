import AVFoundation
import UIKit
import MediaPipeTasksVision
import CoreMotion
import Vision
import RemyCore
import Combine

struct TrackedHand: Identifiable {
    let id: String
    let points: [String: Point2]
    let reachPoint: Point2
    let flatHint: Bool
    /// MediaPipe canned gesture when confident: Thumb_Up, Thumb_Down, Open_Palm, Pointing_Up, Victory, ...
    var gesture: String? = nil
}
struct CameraSample {
    let image: UIImage
    let time: TimeInterval
    let hands: [TrackedHand]
    /// Receipt/capture to matching landmarks and preview preparation; excludes GoPro sensor/network delay.
    let visionMS: Double
    var hazardTracking: (id: UUID, zones: [HazardZone])? = nil
}
struct CameraSnapshot {
    let jpeg: Data
    let time: TimeInterval
}

/// One asynchronous hand request, one replaceable newest frame and one UI delivery at a time.
/// JPEG snapshots run separately at 2.5 Hz; neither Gemma nor compression holds up hand inference.
final class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, GestureRecognizerLiveStreamDelegate {
    @Published var isRunning = false
    @Published var error: String?
    let objects = FastObjectDetector()
    var onFrame: ((CameraSample) -> Void)?
    var onSnapshot: ((CameraSnapshot) -> Void)?
    var onMovement: (() -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "remy.camera", qos: .userInitiated)
    private let snapshotQueue = DispatchQueue(label: "remy.snapshots", qos: .utility)
    private let snapshotSlot = DispatchSemaphore(value: 1)
    private let displaySlot = DispatchSemaphore(value: 1)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    /// MediaPipe Gesture Recognizer: the same hand landmark model as before plus a gesture classifier (thumbs up,
    /// open palm, ...), so hands and gestures come from one LiteRT model per frame.
    private var landmarker: GestureRecognizer?
    private var backend = "MediaPipe · GPU"
    private struct Pending {
        let image: MPImage?
        let preview: UIImage
        let snapshot: UIImage
        let time: Double
        let timestamp: Int
        let generation: UUID
        let hazardTracking: (id: UUID, zones: [HazardZone])?
    }
    // Queue-confined Vision tracker. Each result travels with the exact frame used for hands.
    private struct HazardTrack {
        let id: UUID
        let handler: VNSequenceRequestHandler
        var requests: [VNTrackObjectRequest]
        var labels: [String]
        var time: Double
        let aspect: Double
    }
    private var hazardTrack: HazardTrack?
    private var hazardTrackedFrames = 0
    func setHazardTargets(_ zones: [HazardZone], snapshot: CameraSnapshot, id: UUID) {
        let intent = intentLock.withLock { self.intent }
        queue.async {
            guard self.current(intent), let image = UIImage(data: snapshot.jpeg)?.cgImage, !zones.isEmpty else { return }
            let requests = zones.map { zone in
                VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox:
                    CGRect(x: zone.x, y: 1 - zone.y - zone.height, width: zone.width, height: zone.height)))
            }
            let handler = VNSequenceRequestHandler()
            do {
                try handler.perform(requests, on: image)
                for request in requests {
                    guard let observation = request.results?.first as? VNDetectedObjectObservation else { return }
                    request.inputObservation = observation
                }
                self.hazardTrack = HazardTrack(id: id, handler: handler, requests: requests,
                    labels: zones.map(\.label), time: snapshot.time, aspect: Double(image.width) / Double(image.height))
            } catch { self.hazardTrack = nil }
        }
    }
    func clearHazardTargets() { queue.async { self.hazardTrack = nil } }
    private func trackHazards(in image: UIImage, time: Double) -> (id: UUID, zones: [HazardZone])? {
        guard var track = hazardTrack else { return nil }
        guard let cg = image.cgImage, time > track.time else { return (track.id, []) }
        // Never bridge an interruption or aspect change with a frozen target.
        guard time - track.time < 3, abs(Double(cg.width) / Double(cg.height) - track.aspect) < 0.02 else {
            hazardTrack = nil; return (track.id, [])
        }
        do {
            try track.handler.perform(track.requests, on: cg)
            var zones: [HazardZone] = []
            var requests: [VNTrackObjectRequest] = [], labels: [String] = []
            for (request, label) in zip(track.requests, track.labels) {
                guard let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence >= 0.5 else { continue }
                let box = observation.boundingBox
                let candidate = ItemBox(label: label, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                guard let zone = CookerSafetyTargets.zones(from: [candidate]).first else { continue }
                request.inputObservation = observation
                requests.append(request); labels.append(label); zones.append(zone)
            }
            track.requests = requests; track.labels = labels; track.time = time
            hazardTrack = requests.isEmpty ? nil : track
            if !zones.isEmpty { hazardTrackedFrames += 1 }
            return (track.id, zones)
        } catch { hazardTrack = nil; return (track.id, []) }
    }
    private var ingredientFocus = false
    func setIngredientFocus(_ focused: Bool) {
        queue.async {
            guard self.ingredientFocus != focused else { return }
            self.ingredientFocus = focused
            if focused { self.objects.stop() }
        }
    }
    private var pending: Pending?
    private var lastTimestamp = 0
    private let motion = CMMotionManager()
    private var referenceAttitude: CMAttitude?
    private var configured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var usingExternal = false
    private let externalLock = NSLock()
    private var externalQueued = false
    private var latestExternal: (CVPixelBuffer, Double)?
    private var latestBusy: (CVPixelBuffer, Double)?
    private var completionTimes: [Double] = []
    private let intentLock = NSLock()
    private var intent = UUID()
    private var generation = UUID()
    private var lastSnapshot = 0.0
    private var durations: [Double] = []
    private var processed = 0
    private var dropped = 0
    private var maxHands = 0
    private var startedAt = 0.0
    private var requestedStartAt = 0.0
    private var firstFrameMS = 0.0
    private var trackerReused = false
    private var lastReceipt = 0.0
    private var sourceMean = 0.0
    private var previewMean = 0.0
    private var captureSize = CGSize.zero
    private var displaySize = CGSize.zero
    private var sourceFormat: OSType = 0
    private var trackingPool: CVPixelBufferPool?
    private var trackingPoolSize = CGSize.zero
    private var lastLightCheck = 0.0
    private var captureRequested = false
    private var captureInterrupted = false
    private var interruptionReason = 0
    private var lastCapture = 0.0
    private var lastRecovery = 0.0
    private var captureRestarts = 0
    private var trackerRestarts = 0
    private var watchdog: DispatchSourceTimer?
    private var sessionObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.wasInterruptedNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                let interrupted = note.name == AVCaptureSession.wasInterruptedNotification
                let ended = note.name == AVCaptureSession.interruptionEndedNotification
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? 0
                self.queue.async {
                    if interrupted { self.captureInterrupted = true; self.interruptionReason = reason }
                    print("REMY_CAMERA event \(note.name.rawValue) reason \(reason)")
                    if ended { self.captureInterrupted = false; self.interruptionReason = 0 }
                    if !interrupted { self.recoverCaptureIfNeeded() }
                }
            })
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.recoverCaptureIfNeeded() }
        timer.resume(); watchdog = timer
    }

    deinit {
        watchdog?.cancel()
        for token in sessionObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// AVCapture and MediaPipe can stop delivering without a Swift error. Retry only while this
    /// capture generation is requested, with a cooldown; stale callbacks cannot restart a paused camera.
    private func recoverCaptureIfNeeded() {
        saveCaptureHealth()
        let now = ProcessInfo.processInfo.systemUptime
        guard captureRequested, !usingExternal, current(generation), !captureInterrupted,
              now - requestedStartAt > 3, now - lastRecovery > 3 else { return }
        if !session.isRunning || now - lastCapture > 2 {
            guard captureRestarts < 3 else { return }
            lastRecovery = now; captureRestarts += 1
            session.stopRunning(); session.startRunning()
            print("REMY_CAMERA resumed capture")
        } else if let pending, now - pending.time > 0.7 {
            guard trackerRestarts < 3 else { return }
            lastRecovery = now; trackerRestarts += 1
            self.pending = nil; latestBusy = nil; landmarker = nil
            do { try prepareTracker(id: generation); print("REMY_CAMERA resumed hand tracking") }
            catch { publish(error, id: generation) }
        }
    }


    private func saveCaptureHealth() {
        guard captureRequested else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RuntimeDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try? directory.setResourceValues(flags)
        let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
            "hazardTrackedFrames": hazardTrackedFrames, "hazardTrackerActive": hazardTrack != nil,
            "ingredientFocus": ingredientFocus, "handAndObjectInferenceEnabled": !ingredientFocus,
            "requested": captureRequested, "running": session.isRunning, "interrupted": captureInterrupted,
            "interruptionReason": interruptionReason, "lastCaptureAgeSeconds": max(0, now - lastCapture),
            "pendingAgeSeconds": pending.map { max(0, now - $0.time) } ?? 0,
            "captureRecoveries": captureRestarts, "trackingRecoveries": trackerRestarts,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("capture-health.json"), options: [.atomic, .completeFileProtection])
        }
    }

    private func newIntent() -> UUID {
        intentLock.lock(); defer { intentLock.unlock() }
        intent = UUID(); return intent
    }
    /// A device regression can stop a requested capture to verify real AVFoundation restart,
    /// without presenting the injected interruption as a naturally occurring failure.
    func interruptForDeviceRegression() {
        queue.async { guard self.captureRequested else { return }; self.session.stopRunning() }
    }

    private func current(_ id: UUID) -> Bool {
        intentLock.lock(); defer { intentLock.unlock() }; return intent == id
    }

    func start() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let id = newIntent()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self, self.current(id) else { return }
            guard allowed else {
                DispatchQueue.main.async { if self.current(id) { self.error = "Allow camera access in Settings to watch the board." } }; return
            }
            self.queue.async {
                guard self.current(id) else { return }
                do {
                    self.requestedStartAt = requestedAt
                    try self.prepareTracker(id: id)
                    if !self.configured { try self.configure() }
                    self.captureRestarts = 0; self.trackerRestarts = 0
                    self.usingExternal = false; self.captureRequested = true; self.lastCapture = requestedAt
                    self.session.startRunning()
                    DispatchQueue.main.async {
                        guard self.current(id) else { return }
                        self.isRunning = true; self.error = nil; self.startMotion()
                    }
                } catch { self.publish(error, id: id) }
            }
        }
    }

    func stop(retainingTracker: Bool = false) {
        let id = newIntent()
        objects.stop()
        motion.stopDeviceMotionUpdates(); referenceAttitude = nil
        queue.async {
            guard self.current(id) else { return }
            self.savePerformance(); self.generation = id; self.latestBusy = nil; self.hazardTrack = nil
            self.externalLock.lock(); self.latestExternal = nil; self.externalLock.unlock()
            self.usingExternal = false; self.captureRequested = false; self.session.stopRunning()
            if !retainingTracker { self.pending = nil; self.landmarker = nil }
        }
        isRunning = false
    }

    func prepareExternal() {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let id = newIntent()
        motion.stopDeviceMotionUpdates(); referenceAttitude = nil
        queue.async {
            guard self.current(id) else { return }
            self.requestedStartAt = requestedAt
            self.captureRequested = false; self.session.stopRunning(); self.usingExternal = true
            do {
                try self.prepareTracker(id: id)
                DispatchQueue.main.async { if self.current(id) { self.isRunning = true; self.error = nil } }
            } catch { self.publish(error, id: id) }
        }
    }

    private func prepareTracker(id: UUID) throws {
        generation = id; latestBusy = nil; completionTimes = []; hazardTrack = nil; hazardTrackedFrames = 0
        objects.stop()
        lastSnapshot = 0; durations = []; processed = 0; dropped = 0; maxHands = 0
        startedAt = 0; firstFrameMS = 0; lastReceipt = ProcessInfo.processInfo.systemUptime
        trackerReused = landmarker != nil
        if trackerReused { return }
        pending = nil
        guard let path = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else {
            throw NSError(domain: "Remy.Hands", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled hand gesture model is missing."])
        }
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = path
        // Keep Gemma on Metal; the small tracker uses CPU to avoid competing native GPU scratch pools.
        options.baseOptions.delegate = .CPU
        options.runningMode = .liveStream; options.numHands = 2
        options.minHandDetectionConfidence = 0.5; options.minHandPresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5; options.gestureRecognizerLiveStreamDelegate = self
        landmarker = try GestureRecognizer(options: options); backend = "MediaPipe · CPU"
    }

    func ingestExternal(_ pixel: CVPixelBuffer) {
        externalLock.lock()
        latestExternal = (pixel, ProcessInfo.processInfo.systemUptime)
        let schedule = !externalQueued; externalQueued = true
        externalLock.unlock()
        guard schedule else { return }
        queue.async {
            self.externalLock.lock()
            let next = self.latestExternal; self.latestExternal = nil; self.externalQueued = false
            self.externalLock.unlock()
            guard self.usingExternal, let (pixel, captured) = next else { return }
            self.process(pixel, time: captured)
        }
    }

    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CocoaError(.featureUnsupported) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            // Rotate the captured buffers, so preview, landmarks and tap coordinates stay together.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self, weak connection] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                self?.queue.async { [weak self, weak connection] in
                    guard let self, let connection, connection.videoRotationAngle != angle,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                    if !self.usingExternal {
                        self.latestBusy = nil
                        DispatchQueue.main.async { [weak self] in self?.onMovement?() }
                    }
                }
            }
        }
        configured = true
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }
            guard let reference = self.referenceAttitude else {
                self.referenceAttitude = attitude.copy() as? CMAttitude; return
            }
            let difference = attitude.copy() as! CMAttitude
            difference.multiply(byInverseOf: reference)
            if abs(difference.pitch) + abs(difference.roll) + abs(difference.yaw) > 0.14 {
                self.referenceAttitude = attitude.copy() as? CMAttitude
                self.onMovement?()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !usingExternal, let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        lastCapture = ProcessInfo.processInfo.systemUptime
        process(pixel, time: lastCapture)
    }

    /// Tracking and snapshots use a small immutable image; the phone preview keeps capture detail.
    /// Both images share the same orientation and aspect so normalized landmarks still align.
    private func inputImage(_ pixel: CVPixelBuffer) throws -> (tracking: MPImage?, preview: UIImage, snapshot: UIImage) {
        let input = CIImage(cvPixelBuffer: pixel)
        let scale = min(1, 640 / max(input.extent.width, input.extent.height))
        let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ci.createCGImage(image, from: image.extent) else { throw CocoaError(.coderInvalidValue) }
        let snapshot = UIImage(cgImage: cg)
        let preview: UIImage
        if usingExternal {
            // The GoPro view renders original decoded buffers independently.
            preview = snapshot
        } else {
            guard let full = ci.createCGImage(input, from: input.extent) else { throw CocoaError(.coderInvalidValue) }
            preview = UIImage(cgImage: full)
        }
        captureSize = input.extent.size
        displaySize = preview.size
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLightCheck > 2 {
            lastLightCheck = now; sourceFormat = CVPixelBufferGetPixelFormatType(pixel)
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let planar = CVPixelBufferIsPlanar(pixel)
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixel, 0) : CVPixelBufferGetBaseAddress(pixel)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) : CVPixelBufferGetBytesPerRow(pixel)
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            if let base {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                var total = 0.0
                for row in 1...8 { for col in 1...8 {
                    let x = width * col / 9, y = height * row / 9
                    let offset = y * stride + x * (planar ? 1 : 4)
                    total += planar ? Double(bytes[offset]) : (Double(bytes[offset]) + Double(bytes[offset+1]) + Double(bytes[offset+2])) / 3
                } }
                sourceMean = total / 64
            }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            var rgb = [UInt8](repeating: 0, count: 4)
            rgb.withUnsafeMutableBytes { data in
                if let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
            previewMean = (Double(rgb[0]) + Double(rgb[1]) + Double(rgb[2])) / 3
        }
        if ingredientFocus { return (nil, preview, snapshot) }
        // Give MediaPipe an existing IOSurface-backed buffer. Its UIImage -> GPU conversion uses a fatal
        // CHECK on CVPixelBuffer allocation failure, which cannot be caught by Swift.
        let size = CGSize(width: cg.width, height: cg.height)
        if trackingPool == nil || trackingPoolSize != size {
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: cg.width,
                kCVPixelBufferHeightKey as String: cg.height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferOpenGLESCompatibilityKey as String: true]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
                attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else { throw CameraBufferError.unavailable(status) }
            trackingPool = pool; trackingPoolSize = size
        }
        var trackingBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, trackingPool!,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary, &trackingBuffer)
        guard status == kCVReturnSuccess, let trackingBuffer else { throw CameraBufferError.unavailable(status) }
        ci.render(image, to: trackingBuffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        return (try MPImage(pixelBuffer: trackingBuffer), preview, snapshot)
    }

    private func process(_ pixel: CVPixelBuffer, time now: Double) {
        autoreleasepool { processFrame(pixel, time: now) }
    }

    private func processFrame(_ pixel: CVPixelBuffer, time now: Double) {
        guard current(generation), let landmarker else { return }
        if startedAt == 0 { startedAt = now }
        // No FIFO behind inference. Each result is paired with its exact source image and timestamp.
        guard pending == nil else {
            if latestBusy != nil { dropped += 1 }
            latestBusy = (pixel, now)
            return
        }
        do {
            let (image, preview, snapshot) = try inputImage(pixel)
            let timestamp = max(lastTimestamp + 1, Int(now * 1000)); lastTimestamp = timestamp
            let delivery = Pending(image: image, preview: preview, snapshot: snapshot, time: now, timestamp: timestamp, generation: generation,
                hazardTracking: ingredientFocus ? nil : trackHazards(in: snapshot, time: now))
            if ingredientFocus {
                deliver(delivery, hands: [], now: ProcessInfo.processInfo.systemUptime)
                return
            }
            guard let image else { return }
            pending = delivery
            try landmarker.recognizeAsync(image: image, timestampInMilliseconds: timestamp)
        } catch { pending = nil; publish(error, id: generation) }
    }

    func gestureRecognizer(_ gestureRecognizer: GestureRecognizer, didFinishGestureRecognition result: GestureRecognizerResult?,
                           timestampInMilliseconds: Int, error: Error?) {
        queue.async {
            guard self.landmarker === gestureRecognizer, let pending = self.pending,
                  pending.timestamp == timestampInMilliseconds else { return }
            self.pending = nil
            defer {
                // GoPro may deliver decoded frames in bursts. Consume only the newest waiting frame.
                if let (pixel, time) = self.latestBusy {
                    self.latestBusy = nil
                    if ProcessInfo.processInfo.systemUptime - time < 0.1 { self.process(pixel, time: time) }
                    else { self.dropped += 1 }
                }
            }
            // A retained tracker may finish its pre-pause request. Release it, then drain the newest frame.
            guard self.current(pending.generation) else { return }
            if let error { self.publish(error, id: pending.generation); return }
            let now = ProcessInfo.processInfo.systemUptime
            // A late callback cannot trigger an alert using stale hand positions.
            guard now - pending.time < 0.25 else { self.dropped += 1; return }
            self.deliver(pending, hands: self.hands(from: result), now: now)
        }
    }

    private func deliver(_ pending: Pending, hands: [TrackedHand], now: Double) {
        let ui = pending.preview
        let elapsed = (ProcessInfo.processInfo.systemUptime - pending.time) * 1000
        self.completionTimes.append(now)
        if self.completionTimes.count > 180 { self.completionTimes.removeFirst() }
        if self.processed == 0 { self.firstFrameMS = max(0, (now - self.requestedStartAt) * 1000) }
        self.processed += 1; self.maxHands = max(self.maxHands, hands.count)
        self.durations.append(elapsed); if self.durations.count > 180 { self.durations.removeFirst() }
        if now - self.lastReceipt > 5 { self.savePerformance(); self.lastReceipt = now }
        if !ingredientFocus { objects.submit(pending.snapshot, time: pending.time) }
        let sample = CameraSample(image: ui, time: pending.time, hands: hands, visionMS: elapsed, hazardTracking: pending.hazardTracking)
        if self.displaySlot.wait(timeout: .now()) == .success {
            DispatchQueue.main.async {
                defer { self.displaySlot.signal() }
                guard self.current(pending.generation), ProcessInfo.processInfo.systemUptime - sample.time < 0.25 else { return }
                self.error = nil; self.onFrame?(sample)
            }
        }
        if pending.time - self.lastSnapshot >= 0.4, self.snapshotSlot.wait(timeout: .now()) == .success {
            self.lastSnapshot = pending.time
            self.snapshotQueue.async {
                defer { self.snapshotSlot.signal() }
                guard let jpeg = pending.snapshot.jpegData(compressionQuality: 0.75) else { return }
                DispatchQueue.main.async {
                    guard self.current(pending.generation) else { return }
                    self.onSnapshot?(.init(jpeg: jpeg, time: pending.time))
                }
            }
        }
    }

    private func hands(from result: GestureRecognizerResult?) -> [TrackedHand] {
        guard let result else { return [] }
        return result.landmarks.enumerated().compactMap { index, landmarks in
            guard landmarks.count == 21 else { return nil }
            // MediaPipe normalized image coordinates already have a top-left origin.
            let points = landmarks.map { Point2(Double($0.x), Double($0.y)) }
            guard points.allSatisfy(\.isValid) else { return nil }
            let category = result.handedness.indices.contains(index) ? result.handedness[index].first : nil
            let name = category?.categoryName?.lowercased() ?? "unknown"
            // This camera is unmirrored. Identity only needs to stay consistent; low confidence cannot arm a track.
            let id = (category?.score ?? 0) >= 0.7 && ["left", "right"].contains(name) ? name : "unknown"
            let flat = [(5,6,8), (9,10,12), (13,14,16)].filter { a,b,c in
                let u = Point2(points[a].x - points[b].x, points[a].y - points[b].y)
                let v = Point2(points[c].x - points[b].x, points[c].y - points[b].y)
                let length = hypot(u.x, u.y) * hypot(v.x, v.y)
                return length > 0.0001 && (u.x * v.x + u.y * v.y) / length < -0.85
            }.count
            let top = result.gestures.indices.contains(index) ? result.gestures[index].first : nil
            let gesture = (top?.score ?? 0) >= 0.7 ? top?.categoryName : nil
            return TrackedHand(id: id, points: Dictionary(uniqueKeysWithValues: points.enumerated().map { (String($0.offset), $0.element) }),
                               reachPoint: points[8], flatHint: flat >= 2, gesture: gesture == "None" ? nil : gesture)
        }
    }

    private func publish(_ error: Error, id: UUID) {
        DispatchQueue.main.async { if self.current(id) { self.error = "Hand tracking interrupted: \(error.localizedDescription)" } }
    }

    private func savePerformance() {
        let sorted = durations.sorted()
        func percentile(_ fraction: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
        let elapsed = startedAt > 0 ? ProcessInfo.processInfo.systemUptime - startedAt : 0
        let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "runtime": "MediaPipe Tasks Vision 1.1.1",
            "backend": backend, "source": usingExternal ? "GoPro" : "iPhone", "processedFrames": processed,
            "ingredientFocus": ingredientFocus, "handAndObjectInferenceEnabled": !ingredientFocus,
            "captureRecoveries": captureRestarts, "trackingRecoveries": trackerRestarts, "captureInterrupted": captureInterrupted,
            "busyOrStaleFramesDropped": dropped, "maximumHandsDetected": maxHands, "seconds": elapsed,
            "processedFPS": elapsed > 0 ? Double(processed) / elapsed : 0,
            "recentProcessedFPS": completionTimes.count > 1 ? Double(completionTimes.count - 1) / (completionTimes.last! - completionTimes.first!) : 0, "recentSampleCount": sorted.count,
            "startupToFirstProcessedFrameMS": firstFrameMS, "trackerReused": trackerReused,
            "captureWidth": captureSize.width, "captureHeight": captureSize.height,
            "displayImageWidth": displaySize.width, "displayImageHeight": displaySize.height, "trackingMaximumDimension": 640,
            "sourceMeanByte": sourceMean, "previewMeanByte": previewMean, "sourcePixelFormat": sourceFormat,
            "recentProcessingP50MS": percentile(0.5), "recentProcessingP95MS": percentile(0.95),
            "note": "Capture/decoded-buffer receipt to matching landmarks and image preparation. Excludes camera sensor, GoPro encoding/network and screen presentation delay. No frames are stored."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("latest-hand-tracking.json")
        snapshotQueue.async {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
        }
    }
}

private enum CameraBufferError: LocalizedError {
    case unavailable(CVReturn)
    var errorDescription: String? { "Hand tracking could not allocate an image buffer. Pause the camera, then try again." }
}
