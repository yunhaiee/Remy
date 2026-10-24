import Foundation
import CryptoKit
import Combine

struct ModelManifest: Codable, Sendable {
    let repository: String
    let revision: String
    let filename: String
    let size: Int64
    let sha256: String
    let runtime: String
    let url: URL
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// Only model setup uses the network. Camera and inference have no HTTP/API client.
@MainActor final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var status = "No model installed"
    @Published var progress: Double = 0
    @Published var isWorking = false
    @Published var modelURL: URL?
    @Published var error: String?
    let manifest: ModelManifest
    private var task: URLSessionDownloadTask?
    private var transfer: URLSession?
    let directory: URL

    override init() {
        // A missing build resource is a packaging error; surface it during development.
        manifest = try! ModelManifest.bundled()
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(manifest.filename)
        if FileManager.default.fileExists(atPath: file.path) {
            status = "Verifying local model…"; isWorking = true
            Task { await verifyExisting(file) }
        }
    }

    func download() {
        guard !isWorking else { return }
        error = nil; isWorking = true; progress = 0; status = "Downloading Gemma · setup only"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 7200
        config.allowsCellularAccess = false
        transfer = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = transfer?.downloadTask(with: manifest.url)
        task?.resume()
    }

    func cancelDownload() {
        task?.cancel(); transfer?.invalidateAndCancel(); transfer = nil
        isWorking = false; status = "Download cancelled"
    }

    func importFile(_ source: URL) async {
        guard !isWorking else { return }
        isWorking = true; error = nil; status = "Importing and checking Gemma…"
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let manifest = manifest, destination = directory.appendingPathComponent(manifest.filename)
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.verify(source, manifest: manifest)
                if source.standardizedFileURL != destination.standardizedFileURL {
                    let staging = destination.appendingPathExtension("importing")
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.copyItem(at: source, to: staging)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else { try FileManager.default.moveItem(at: staging, to: destination) }
                }
            }.value
            modelURL = destination; status = "Gemma verified · stored on this iPhone"
        } catch { self.error = error.localizedDescription; status = "Import failed" }
        isWorking = false
    }

    private func verifyExisting(_ url: URL) async {
        let manifest = manifest
        do {
            try await Task.detached(priority: .utility) { try Self.verify(url, manifest: manifest) }.value
            modelURL = url; status = "Gemma verified · stored on this iPhone"
        } catch { self.error = error.localizedDescription; status = "Model needs replacing" }
        isWorking = false
    }

    nonisolated static func verify(_ url: URL, manifest: ModelManifest) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == manifest.size else { throw RunnerError.invalidModel }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256 else { throw RunnerError.invalidModel }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.progress = min(1, Double(totalBytesWritten) / Double(self.manifest.size))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The delegate's temporary file is only valid until this callback returns.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: staging)
            Task { @MainActor in
                self.isWorking = false
                await self.importFile(staging)
                try? FileManager.default.removeItem(at: staging)
                session.finishTasksAndInvalidate()
                self.transfer = nil
            }
        } catch {
            Task { @MainActor in self.error = error.localizedDescription; self.isWorking = false; self.status = "Download failed" }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.error = error.localizedDescription; self.isWorking = false; self.status = "Download stopped" }
    }
}
