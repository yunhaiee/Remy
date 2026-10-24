import Foundation
import Network
import RemyCore

/// The wired path cannot silently use Wi-Fi, cellular, or peer-to-peer wireless.
enum WiredGoProHTTP {
    static func get(host: String, path: String, wired: Bool = true) async throws -> Data {
        let transaction = WiredHTTPTransaction(host: host, path: path, wired: wired)
        return try await withTaskCancellationHandler {
            try await transaction.run()
        } onCancel: { transaction.cancel() }
    }
}

private final class WiredHTTPTransaction: @unchecked Sendable {
    private let host: String
    private let path: String
    private let wired: Bool
    private let queue = DispatchQueue(label: "remy.gopro.usb-http")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var response = Data()
    private var cancelled = false
    init(host: String, path: String, wired: Bool) { self.host = host; self.path = path; self.wired = wired }
    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                guard !self.cancelled else { self.finish(.failure(CancellationError())); return }
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = self.wired ? .wiredEthernet : .wifi
                parameters.prohibitedInterfaceTypes = self.wired ? [.wifi, .cellular] : [.wiredEthernet, .cellular]
                parameters.includePeerToPeer = false
                let connection = NWConnection(host: .init(self.host), port: 8080, using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard connection.currentPath?.usesInterfaceType(self.wired ? .wiredEthernet : .wifi) == true else {
                            self.finish(.failure(URLError(.notConnectedToInternet))); return
                        }
                        self.send()
                    case .failed(let error): self.finish(.failure(error))
                    case .waiting:
                        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                            self.finish(.failure(GoProNetworkError.localNetworkDenied))
                        }
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 7) { self.finish(.failure(URLError(.timedOut))) }
            }
        }
    }
    func cancel() { queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } }
    private func send() {
        let request = "GET /\(path) HTTP/1.1\r\nHost: \(host):8080\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish(.failure(error)) } else { self.receive() }
        })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.continuation != nil else { return }
            if let data { self.response.append(data) }
            do {
                if let body = try GoProHTTP.body(in: self.response, connectionClosed: complete) {
                    self.finish(.success(body)); return
                }
                if let error { self.finish(.failure(error)); return }
                self.receive()
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        continuation.resume(with: result)
    }
}

private enum GoProNetworkError: LocalizedError {
    case localNetworkDenied
    var errorDescription: String? { "Local Network access is blocked. Enable it for Remy in iPhone Settings, then retry." }
}
