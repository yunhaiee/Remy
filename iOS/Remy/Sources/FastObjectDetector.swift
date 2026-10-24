import Foundation
import UIKit
import MediaPipeTasksVision
import RemyCore

struct ObjectDetectionSample {
    let boxes: [ItemBox]
    let time: Double
    let aspect: Double
    let elapsedMS: Double
    /// "EfficientDet-Lite0 · LiteRT · CPU" or "YOLOX-M · Core ML", for Evidence.
    let model: String
}

/// EfficientDet-Lite0 on LiteRT (MediaPipe Object Detector, CPU) by default, so the hands, the detector and Gemma are
/// three LiteRT models running at once. YOLOX-M on Core ML only when it is bundled and Settings turns it on.
/// Independent of Gemma and the hand tracker. One request may be in flight;
/// incoming frames are dropped while busy, so a slow detector never builds up a video backlog.
final class FastObjectDetector {
    private let queue = DispatchQueue(label: "remy.objects", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var generation = UUID()
    private var lastSubmitted = 0.0
    private var detector: ObjectDetector?
    private var core: CoreMLKitchenDetector?
    private var coreUnavailable = true
    /// Settings → Core ML detector. Read and written on `queue` only.
    private var wantsCoreML = false
    private var durations: [Double] = []
    private var lastReceipt = 0.0
    var onResult: ((ObjectDetectionSample) -> Void)?

    /// Switch between the LiteRT detector and the optional Core ML YOLOX-M; takes effect on the next frame.
    func setCoreML(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsCoreML = on; self.core = nil; self.coreUnavailable = !on
        }
    }

    func stop() {
        lock.lock(); generation = UUID(); lastSubmitted = 0; lock.unlock()
    }

    func submit(_ image: UIImage, time: Double) {
        let thermalState = ProcessInfo.processInfo.thermalState
        // Leave headroom for video, hands, and Gemma when the phone is thermally constrained.
        let targetSubmissionHz = (thermalState == .serious || thermalState == .critical) ? 5.0 : 10.0
        lock.lock()
        guard !busy, time - lastSubmitted >= 1 / targetSubmissionHz else { lock.unlock(); return }
        busy = true; lastSubmitted = time; let id = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            autoreleasepool {
                do {
                    if self.wantsCoreML, self.core == nil, !self.coreUnavailable {
                        self.coreUnavailable = true
                        if #available(iOS 18, *), let url = Bundle.main.url(forResource: "yolox_m", withExtension: "mlmodelc") {
                            self.core = try? CoreMLKitchenDetector(compiledModel: url)
                        }
                    }
                    if self.core == nil, self.detector == nil {
                        guard let path = Bundle.main.path(forResource: "efficientdet_lite0", ofType: "tflite") else { return }
                        self.detector = try Self.make(path: path, gpu: false)
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    let boxes: [ItemBox]
                    if let core = self.core {
                        boxes = try core.detect(image).map { d in
                            ItemBox(label: d.label, x: d.rect.minX / image.size.width, y: d.rect.minY / image.size.height,
                                    width: d.rect.width / image.size.width, height: d.rect.height / image.size.height)
                        }
                    } else {
                        boxes = Self.boxes(try self.detector!.detect(image: MPImage(uiImage: image)), size: image.size)
                    }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    let model = self.core == nil ? Self.liteRTName : Self.coreMLName
                    self.durations.append(elapsed)
                    if self.durations.count > 120 { self.durations.removeFirst() }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastReceipt > 5 {
                        self.lastReceipt = now
                        let sorted = self.durations.sorted()
                        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("RuntimeDiagnostics", isDirectory: true)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                        try? directory.setResourceValues(flags)
                        let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
                            "model": self.core == nil ? "EfficientDet-Lite0 int8" : "YOLOX-M float16",
                            "backend": self.core == nil ? "CPU" : "Core ML CPU + Neural Engine", "samples": sorted.count,
                            "targetSubmissionHz": targetSubmissionHz, "thermalState": thermalState.rawValue,
                            "medianMS": sorted[sorted.count / 2], "p95MS": sorted[Int(Double(sorted.count - 1) * 0.95)]]
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                            try? data.write(to: directory.appendingPathComponent("detector-performance.json"), options: [.atomic, .completeFileProtection])
                        }
                    }
                    DispatchQueue.main.async {
                        self.lock.lock(); let valid = self.generation == id; self.lock.unlock()
                        guard valid, ProcessInfo.processInfo.systemUptime - time < 0.5 else { return }
                        self.onResult?(.init(boxes: boxes, time: time, aspect: image.size.width / image.size.height, elapsedMS: elapsed,
                                             model: model))
                    }
                } catch {
                    // Detection is optional. A failed or missing model must not stop video or hand tracking.
                    self.core = nil; self.coreUnavailable = true; self.detector = nil
                }
            }
        }
    }

    static let liteRTName = "EfficientDet-Lite0 · LiteRT · CPU"
    static let coreMLName = "YOLOX-M · Core ML"

    static func make(path: String, gpu: Bool) throws -> ObjectDetector {
        let options = ObjectDetectorOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = gpu ? .GPU : .CPU
        options.runningMode = .image
        options.maxResults = 8
        options.scoreThreshold = 0.5
        return try ObjectDetector(options: options)
    }

    static func boxes(_ result: ObjectDetectorResult, size: CGSize) -> [ItemBox] {
        guard size.width > 0, size.height > 0 else { return [] }
        return result.detections.compactMap { detection in
            guard let category = detection.categories.first, let name = category.categoryName, !name.isEmpty else { return nil }
            let r = detection.boundingBox.intersection(CGRect(origin: .zero, size: size))
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            return ItemBox(label: name, x: r.minX / size.width, y: r.minY / size.height,
                           width: r.width / size.width, height: r.height / size.height)
        }
    }

    /// Public COCO fixture only; reports latency and expected-category checks, never camera images.
    static func benchmark() async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DetectorModels")
            var rows: [[String: Any]] = []
            guard let image = UIImage(contentsOfFile: dir.appendingPathComponent("cats.jpg").path) else { return }
            for model in ["efficientdet_lite0", "ssd_mobilenet_v2"] {
                for gpu in [false, true] {
                    var row: [String: Any] = ["model": model, "backend": gpu ? "GPU" : "CPU"]
                    do {
                        let start = ProcessInfo.processInfo.systemUptime
                        let detector = try make(path: dir.appendingPathComponent(model + ".tflite").path, gpu: gpu)
                        row["loadMS"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        var durations: [Double] = [], cats: [Int] = []
                        for _ in 0..<21 {
                            try autoreleasepool {
                                let start = ProcessInfo.processInfo.systemUptime
                                let result = try detector.detect(image: MPImage(uiImage: image))
                                durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                                cats.append(boxes(result, size: image.size).filter { $0.label == "cat" }.count)
                            }
                        }
                        row["coldMS"] = durations.removeFirst()
                        let sorted = durations.sorted()
                        row["warmMedianMS"] = sorted[sorted.count / 2]
                        row["warmP95MS"] = sorted[Int(Double(sorted.count - 1) * 0.95)]
                        row["twoCatsDetectedEachRun"] = cats.allSatisfy { $0 == 2 }
                        row["catCounts"] = cats
                        row["passed"] = true
                    } catch { row["passed"] = false; row["error"] = error.localizedDescription }
                    rows.append(row)
                }
            }
            let report: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
                "fixture": "public COCO 2017 val 000000039769; two cats, not cooking accuracy validation", "results": rows]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("benchmark.json"), options: [.atomic, .completeFileProtection])
            }
        }.value
    }
}
