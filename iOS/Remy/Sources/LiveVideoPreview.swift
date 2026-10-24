import AVFoundation
import SwiftUI

/// At most two decoded frames smooth paired UDP/decode arrivals. No queue can grow behind tracking or UI.
final class LiveVideoFrames: @unchecked Sendable {
    struct Frame {
        let pixel: CVPixelBuffer
        let id: UInt64
        let received: Double
    }
    private let lock = NSLock()
    private var pendingFrames: [Frame] = []
    private var coalesced = 0
    private var decoded: UInt64 = 0
    private var shown = 0
    private var lastShown: UInt64?
    private var decodeTimes: [Double] = []
    private var shownTimes: [Double] = []
    private var queueMS: [Double] = []
    private var tickTimes: [Double] = []
    private var backpressure = 0
    private var renderError: String?
    private var sessionID = UUID()

    func begin(_ id: UUID) {
        clear(resetCounters: true)
        lock.lock(); sessionID = id; lock.unlock()
    }
    func put(_ pixel: CVPixelBuffer, session: UUID) -> UInt64? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard session == sessionID else { return nil }
        decoded += 1; pendingFrames.append(.init(pixel: pixel, id: decoded, received: now))
        if pendingFrames.count > 2 { pendingFrames.removeFirst(); coalesced += 1 }
        decodeTimes.append(now); if decodeTimes.count > 180 { decodeTimes.removeFirst() }
        return decoded
    }
    func read() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        while let first = pendingFrames.first, now - first.received > 0.09 { pendingFrames.removeFirst(); coalesced += 1 }
        return pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
    }
    func clear(resetCounters: Bool = false) {
        lock.lock(); defer { lock.unlock() }; pendingFrames = []; sessionID = UUID()
        if resetCounters { decoded = 0; coalesced = 0; shown = 0; lastShown = nil; decodeTimes = []; shownTimes = []; queueMS = []; tickTimes = []; backpressure = 0; renderError = nil }
    }
    func presented(_ frame: Frame) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard lastShown != frame.id else { return }
        lastShown = frame.id; shown += 1; shownTimes.append(now); queueMS.append((now - frame.received) * 1000)
        if shownTimes.count > 180 { shownTimes.removeFirst(); queueMS.removeFirst() }
    }
    func tick() {
        lock.lock(); defer { lock.unlock() }
        tickTimes.append(ProcessInfo.processInfo.systemUptime)
        if tickTimes.count > 180 { tickTimes.removeFirst() }
    }
    func blocked() { lock.lock(); backpressure += 1; lock.unlock() }
    func failed(_ text: String) { lock.lock(); renderError = text; lock.unlock() }
    func statistics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        func fps(_ times: [Double]) -> Double {
            guard let first = times.first, let last = times.last, last > first else { return 0 }
            return Double(times.count - 1) / (last - first)
        }
        let decodeGaps = zip(decodeTimes.dropFirst(), decodeTimes).map { ($0.0 - $0.1) * 1000 }.sorted()
        let sorted = queueMS.sorted()
        func percentile(_ fraction: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
        return ["decodedFrames": decoded, "enqueuedPreviewFrames": shown, "coalescedOrExpiredFrames": coalesced, "maximumPendingFrames": 2, "recentDisplayTickFPS": fps(tickTimes), "rendererBackpressureSkips": backpressure, "recentDecodeFPS": fps(decodeTimes),
            "recentDecodeGapP50MS": decodeGaps.isEmpty ? 0 : decodeGaps[decodeGaps.count / 2],
            "recentDecodeGapP95MS": decodeGaps.isEmpty ? 0 : decodeGaps[min(decodeGaps.count - 1, Int(Double(decodeGaps.count - 1) * 0.95))],
            "recentPreviewEnqueueFPS": fps(shownTimes), "recentPreviewQueueP50MS": percentile(0.5),
            "recentPreviewQueueP95MS": percentile(0.95), "rendererError": renderError as Any? ?? NSNull(),
            "note": "Decoded-buffer receipt to immediate native renderer enqueue. Excludes GoPro camera/encoding/network and physical display scanout."]
    }
}

struct LiveVideoPreview: UIViewRepresentable {
    let frames: LiveVideoFrames
    var enabled = true
    var scaling: SwiftUI.ContentMode = .fit
    func makeUIView(context: Context) -> LiveVideoSurface { LiveVideoSurface(frames: frames) }
    func updateUIView(_ view: LiveVideoSurface, context: Context) {
        view.frames = frames
        view.enabled = enabled
        view.scaling = scaling
    }
    static func dismantleUIView(_ view: LiveVideoSurface, coordinator: ()) { view.stop() }
}

final class LiveVideoSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var frames: LiveVideoFrames
    var enabled = true { didSet { link?.isPaused = !enabled } }
    var scaling: SwiftUI.ContentMode = .fit {
        didSet { videoLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect }
    }
    private var link: CADisplayLink?
    private var lastID: UInt64?
    private var format: CMVideoFormatDescription?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private class Tick: NSObject {
        weak var owner: LiveVideoSurface?
        init(_ owner: LiveVideoSurface) { self.owner = owner }
        @objc func fire() { owner?.drawNewest() }
    }
    init(frames: LiveVideoFrames) {
        self.frames = frames; super.init(frame: .zero)
        videoLayer.videoGravity = .resizeAspect; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
        else if link == nil {
            let tick = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire))
            tick.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            tick.isPaused = !enabled; tick.add(to: .main, forMode: .common); link = tick
        }
    }
    func stop() { link?.invalidate(); link = nil }
    private func drawNewest() {
        guard enabled else { return }
        frames.tick()
        guard let frame = frames.read() else { return }
        guard frame.id != lastID, ProcessInfo.processInfo.systemUptime - frame.received < 0.25 else { return }
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed { frames.failed(renderer.error?.localizedDescription ?? "Native renderer failed"); renderer.flush() }
        // Never build up the renderer queue; the next tick consumes from a maximum of two fresh frames.
        guard renderer.isReadyForMoreMediaData else { frames.blocked(); return }
        let width = Int32(CVPixelBufferGetWidth(frame.pixel)), height = Int32(CVPixelBufferGetHeight(frame.pixel))
        if format == nil || width != dimensions.width || height != dimensions.height {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixel, formatDescriptionOut: &format)
            dimensions = .init(width: width, height: height)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: frame.received, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample); lastID = frame.id; frames.presented(frame)
    }
}
