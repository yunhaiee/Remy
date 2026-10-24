import Foundation
import Network
import Combine
import CoreVideo
import RemyCore

@MainActor final class GoProSource: ObservableObject {
    @Published var host = ""
    @Published var serialSuffix = ""
    @Published var wiredMode = true {
        didSet {
            host = wiredMode ? GoProAddress.wired(serialSuffix: serialSuffix) ?? "" : "10.5.5.9"
            if !running && !connecting {
                connected = false; error = nil
                status = wiredMode ? "Ready for a USB cable test" : "Ready for Bluetooth setup and a Wi-Fi video test"
            }
        }
    }
    @Published var status = "Ready for a USB cable test"
    @Published var connected = false
    @Published var connecting = false
    @Published var running = false
    @Published var packets = 0
    @Published var frames = 0
    @Published var error: String?
    @Published var wiredAvailable = false
    @Published var wiredStatus = "Waiting for a wired network interface"
    @Published var cameraSubnetStatus = "Camera Wi-Fi address not checked"
    @Published var events: [String] = []
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    let videoFrames = LiveVideoFrames()
    private var rawFrames = 0
    private var lastStatsAt = 0.0
    private let queue = DispatchQueue(label: "remy.gopro", qos: .userInitiated)
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private var receiver: PreviewReceiver?
    private var stopPath: String?
    private var activeHost: String?
    private var activeWired = true
    private var transferID = UUID()
    private var lastFrameAt: Date?
    private var videoStalled = false
    private var pendingStop: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var wantsStreaming = false
    private var keepAliveTask: Task<Void, Never>?
    private var keepAliveReplies = 0

    init() {
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--gopro-serial=") }
        serialSuffix = argument.map { String($0.dropFirst("--gopro-serial=".count)) }
            ?? UserDefaults.standard.string(forKey: "gopro.serialSuffix") ?? ""
        useSerialAddress()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let names = path.availableInterfaces.filter { $0.type == .wiredEthernet }.map(\.name).joined(separator: ", ")
            Task { @MainActor in
                guard let self else { return }
                let summary = available ? "Wired interface available: \(names)" : "No wired network interface detected"
                if self.wiredStatus != summary { self.wiredStatus = summary; self.wiredAvailable = available; self.log(summary) }
            }
        }
        pathMonitor.start(queue: queue)
    }

    func useSerialAddress() {
        if let address = GoProAddress.wired(serialSuffix: serialSuffix) {
            UserDefaults.standard.set(serialSuffix, forKey: "gopro.serialSuffix")
            if wiredMode { host = address }
        } else if wiredMode { host = "" }
    }

    func probe() async {
        guard !connecting, !running else { return }
        let id = UUID(); transferID = id; connecting = true; error = nil
        defer { if transferID == id { connecting = false } }
        do { try await checkCamera(id: id) }
        catch { report(error, id: id) }
    }

    private func checkCamera(id: UUID) async throws {
        connected = false
        if !wiredMode {
            if let address = GoProNetworkCheck.cameraSubnetAddress() {
                cameraSubnetStatus = "iPhone camera-network address: \(address)"
            } else {
                cameraSubnetStatus = "No iPhone address on the GoPro network"
            }
            log(cameraSubnetStatus)
        }
        status = wiredMode ? "Testing the HERO12 over USB only…" : "Checking the GoPro’s Wi-Fi HTTP API…"
        log("Checking camera at \(host):8080 via \(wiredMode ? "USB-only" : "local Wi-Fi")")
        let data = try await command("gopro/camera/info", host: host, wired: wiredMode)
        guard transferID == id else { throw CancellationError() }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model_name"] as? String,
              model.lowercased().contains("hero12") || model.lowercased().contains("hero 12") else {
            throw GoProError.message("HTTP answered, but it did not identify a HERO12. Check the camera address.")
        }
        connected = true; status = "HERO12 control reached. Video has not started."
        log("Camera identified as \(model). HTTP control reached.")
    }

    func start(isRecovery: Bool = false) async {
        guard !running, !connecting else { return }
        if !isRecovery { recoveryTask?.cancel(); recoveryTask = nil; recoveryAttempts = 0 }
        wantsStreaming = true
        let id = UUID(); transferID = id; connecting = true; error = nil
        rawFrames = 0; lastStatsAt = 0; videoFrames.begin(id)
        packets = 0; frames = 0; lastFrameAt = nil; videoStalled = false; keepAliveReplies = 0
        keepAliveTask?.cancel(); keepAliveTask = nil
        defer { if transferID == id { connecting = false } }
        var pendingReceiver: PreviewReceiver?
        do {
            await pendingStop?.value
            guard transferID == id else { return }
            try await checkCamera(id: id)
            guard transferID == id else { return }
            let selectedHost = host, wired = wiredMode
            if wired {
                status = "Preparing USB camera control…"
                _ = try await command("gopro/camera/control/wired_usb?p=1", host: selectedHost, wired: true)
                guard transferID == id else { return }
                // Match the official SDK: stop capture before entering webcam mode.
                _ = try await command("gopro/camera/shutter/stop", host: selectedHost, wired: true)
                guard transferID == id else { return }
            } else {
                status = "Clearing any previous camera preview…"
                do { _ = try await command("gopro/camera/stream/stop", host: selectedHost, wired: false) }
                catch GoProWireError.httpStatus(409) { /* No active preview is also a valid starting state. */ }
                guard transferID == id else { return }
                log("Previous preview cleared before binding the video receiver.")
            }
            let receiver = PreviewReceiver(queue: queue, expectedHost: selectedHost, wired: wired)
            pendingReceiver = receiver
            let frameSink = onFrame
            let videoFrames = self.videoFrames
            let statsSlot = DispatchSemaphore(value: 1)
            receiver.onFrame = { [weak self] buffer in
                // Native preview and tracking input are independent of the main UI queue.
                guard let decodedCount = videoFrames.put(buffer, session: id) else { return }
                frameSink?(buffer)
                guard statsSlot.wait(timeout: .now()) == .success else { return }
                Task { @MainActor in
                    defer { statsSlot.signal() }
                    guard let self, self.transferID == id, self.running else { return }
                    self.rawFrames = Int(decodedCount); self.lastFrameAt = Date()
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastStatsAt > 0.5 { self.frames = self.rawFrames; self.lastStatsAt = now }
                    if self.rawFrames == 1 || self.videoStalled {
                        self.frames = self.rawFrames
                        self.status = "Live HERO12 video · \(wired ? "USB cable" : "Wi-Fi")"
                        self.videoStalled = false; self.error = nil
                        self.log(self.rawFrames == 1 ? "First real H.264 frame decoded on iPhone." : "Live video resumed.")
                    }
                }
            }
            receiver.onPacketCount = { [weak self] count in Task { @MainActor in
                guard let self, self.transferID == id else { return }
                self.packets = count
                if count == 1 { self.log("First UDP video packet received.") }
            } }
            receiver.onError = { [weak self] message in Task { @MainActor in
                guard let self, self.transferID == id else { return }; self.error = message
                self.log(message)
            } }
            try await receiver.start()
            guard transferID == id else { receiver.stop(); return }
            self.receiver = receiver; running = true; activeHost = selectedHost; activeWired = wired
            // Omit protocol: GoPro's documented default is MPEG-TS over UDP.
            let path = wired ? "gopro/webcam/start?port=8554" : "gopro/camera/stream/start?port=8554"
            stopPath = wired ? "gopro/webcam/stop" : "gopro/camera/stream/stop"
            let reply = try await requestStream(path, host: selectedHost, wired: wired, id: id)
            guard transferID == id else { return }
            if let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
               let code = json["error"] as? Int, code != 0 {
                throw GoProError.message("GoPro rejected webcam start (camera error \(code)). Stop recording and retry.")
            }
            log("Camera accepted the stream request. Waiting for actual frames.")
            // Official Open GoPro heartbeat prevents the idle camera from powering down.
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self, self.transferID == id, self.running else { return }
                    do {
                        _ = try await self.command("gopro/camera/keep_alive", host: selectedHost, wired: wired)
                        if self.transferID == id { self.keepAliveReplies += 1 }
                    } catch {
                        guard self.transferID == id else { return }
                        // The frame watchdog owns recovery; a single control timeout must not stop live video.
                    }
                }
            }
            if rawFrames == 0 { status = "Stream requested. Waiting for video…" }
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard self.transferID == id, self.running, self.rawFrames == 0 else { return }
                self.error = self.packets == 0
                    ? "Control worked, but no video packets arrived over the selected connection."
                    : "Packets arrived, but no H.264 frame decoded. Keep this screen open and export diagnostics."
                self.log(self.error!)
                self.scheduleRecovery(id: id)
            }
            Task {
                var ticks = 0
                while self.transferID == id && self.running {
                    try? await Task.sleep(for: .seconds(1))
                    guard self.transferID == id, self.running else { return }
                    ticks += 1
                    if ticks % 5 == 0 { _ = self.exportDiagnostics() }
                    if let last = self.lastFrameAt, Date().timeIntervalSince(last) > 3, !self.videoStalled {
                        self.videoStalled = true; self.status = "Video paused · waiting for frames"
                        self.error = "Video stopped arriving. Reconnecting to the camera…"
                        self.log(self.error!)
                        self.scheduleRecovery(id: id)
                    }
                }
            }
        } catch {
            pendingReceiver?.stop()
            guard transferID == id else { return }
            self.receiver = nil; running = false
            report(error, id: id)
            scheduleRecovery(id: id)
        }
    }

    private func requestStream(_ path: String, host: String, wired: Bool, id: UUID) async throws -> Data {
        for retry in 0..<3 {
            guard transferID == id else { throw CancellationError() }
            do { return try await command(path, host: host, wired: wired) }
            catch GoProWireError.httpStatus(409) where !wired && retry < 2 {
                log("Camera is finishing the previous preview; waiting before stream start.")
                try await Task.sleep(for: .milliseconds(250 * (retry + 1)))
            }
        }
        throw GoProWireError.httpStatus(409)
    }

    /// Retry transient startup/stall failures without requiring a source toggle. Stop always cancels recovery.
    private func scheduleRecovery(id: UUID) {
        guard wantsStreaming, transferID == id, recoveryTask == nil else { return }
        guard recoveryAttempts < 3 else {
            // Leave Connect usable after the retry budget; a failed receiver is not a live preview.
            receiver?.stop(); receiver = nil; running = false; connecting = false; wantsStreaming = false
            keepAliveTask?.cancel(); keepAliveTask = nil
            status = "Reconnect paused"
            error = "Three reconnect attempts failed. Check camera power and join its Wi-Fi, then tap Connect."
            log(error!); return
        }
        recoveryAttempts += 1
        let delay = recoveryAttempts
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsStreaming, self.transferID == id else { return }
            self.recoveryTask = nil
            // A short interruption that already recovered needs no restart.
            if self.running, let last = self.lastFrameAt, Date().timeIntervalSince(last) < 1 { return }
            self.log("Automatic reconnect attempt \(self.recoveryAttempts) of 3.")
            self.receiver?.stop(); self.receiver = nil; self.running = false; self.connecting = false
            if let host = self.activeHost, let path = self.stopPath {
                let wired = self.activeWired
                self.pendingStop = Task { _ = try? await self.command(path, host: host, wired: wired) }
            }
            await self.start(isRecovery: true)
        }
    }

    func stop() {
        wantsStreaming = false; recoveryTask?.cancel(); recoveryTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        transferID = UUID(); connecting = false; receiver?.stop(); receiver = nil; running = false
        frames = rawFrames; videoFrames.clear()
        status = "GoPro preview stopped"; log(status)
        if let host = activeHost, let path = stopPath {
            let wired = activeWired
            pendingStop = Task { _ = try? await command(path, host: host, wired: wired) }
        }
        stopPath = nil; activeHost = nil
    }

    private func report(_ error: Error, id: UUID) {
        guard transferID == id else { return }
        status = "GoPro connection needs attention"
        if wiredMode && !wiredAvailable {
            self.error = "iOS has not exposed a wired network connection. Check the data cable, unlock the phone, and keep the GoPro powered on. Direct USB support is still being tested."
        } else { self.error = error.localizedDescription }
        log("\(self.error!) [\(error.localizedDescription)]")
    }

    private func command(_ path: String, host: String, wired: Bool) async throws -> Data {
        guard GoProAddress.isLocalIPv4(host) else {
            throw GoProError.message("Enter three serial-number digits or a valid private camera IPv4 address.")
        }
        return try await WiredGoProHTTP.get(host: host, path: path, wired: wired)
    }

    private func log(_ message: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date()))  \(message)")
        if events.count > 50 { events.removeFirst(events.count - 50) }
        _ = exportDiagnostics()
    }

    var diagnosticsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("latest-gopro-connection.json")
    }

    func exportDiagnostics() -> URL {
        let url = diagnosticsURL
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": wiredMode ? "USB-only" : "Wi-Fi", "cameraAddress": host,
            "wiredInterface": wiredStatus, "httpReached": connected,
            "cameraSubnet": cameraSubnetStatus,
            "packets": packets, "decodedFrames": rawFrames, "nativePreview": videoFrames.statistics(), "status": status, "reconnectAttempts": recoveryAttempts, "keepAliveReplies": keepAliveReplies,
            "error": error as Any? ?? NSNull(), "events": events,
            "lastDecodedFrame": lastFrameAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }
}

private enum GoProError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Every demux/decode operation is confined to one queue. The decoder emits real pixel buffers only.
private final class PreviewReceiver {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onPacketCount: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    private let queue: DispatchQueue
    private let expectedHost: String
    private let wired: Bool
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var demux = TransportStreamDemuxer()
    private let decoder = H264PreviewDecoder()
    private var count = 0
    private var stopped = false
    private var startGate: ListenerStartGate?
    init(queue: DispatchQueue, expectedHost: String, wired: Bool) { self.queue = queue; self.expectedHost = expectedHost; self.wired = wired }
    func start() async throws {
        decoder.onFrame = { [weak self] in self?.onFrame?($0) }
        decoder.onError = { [weak self] in self?.onError?($0) }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo
        if wired {
            parameters.requiredInterfaceType = .wiredEthernet
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular]
            parameters.includePeerToPeer = false
        } else {
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.wiredEthernet, .cellular]
            parameters.includePeerToPeer = false
        }
        let listener = try NWListener(using: parameters, on: 8554)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.connections.isEmpty else { connection.cancel(); return }
            guard case .hostPort(let address, _) = connection.endpoint,
                  address.debugDescription == self.expectedHost else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ListenerStartGate(continuation)
            self.startGate = gate
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { gate.finish(.failure(URLError(.timedOut))) }
        }
    }
    func stop() { queue.async {
        self.stopped = true; self.startGate?.finish(.failure(CancellationError())); self.startGate = nil
        self.listener?.stateUpdateHandler = nil; self.listener?.cancel()
        self.connections.forEach { $0.cancel() }; self.connections = []
    } }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data {
                self.count += 1
                if self.count % 30 == 1 { self.onPacketCount?(self.count) }
                let dropped = self.demux.droppedPackets
                let frames = self.demux.append(data)
                if self.demux.droppedPackets != dropped { self.decoder.lostPacket() }
                frames.forEach { self.decoder.decode($0) }
            }
            if let error { self.onError?("Preview receiver: \(error.localizedDescription)") }
            else if connection.state != .cancelled { self.receive(connection) }
        }
    }
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
