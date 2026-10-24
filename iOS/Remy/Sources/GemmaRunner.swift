import Foundation
import LiteRTLM
import RemyCore

struct InferenceResult: Sendable {
    let text: String
    let elapsedMS: Double
    let imageCount: Int
    /// Prefill/decode token speeds, only when LiteRT-LM benchmarking is enabled (RemyEval).
    var speed: String? = nil
}

/// Actor confinement keeps model initialization and inference off the UI and serializes SDK access.
actor GemmaRunner {
    private var engine: Engine?
    private var busy = false
    private var suspended = false
    private var sceneRevision = 0
    nonisolated var requiresRestart: Bool { Conversation.safeInferenceRequiresRestart }
    func setSuspended(_ value: Bool, revision: Int) {
        guard revision > sceneRevision else { return }
        sceneRevision = revision
        suspended = value
    }

    private func requireHealthyForeground() throws {
        guard !suspended else { throw RunnerError.inBackground }
        guard !Conversation.safeInferenceRequiresRestart else { throw RunnerError.restartRequired }
    }
    private var onBackendChanged: (@Sendable (String) -> Void)?
    private(set) var backend = "Not loaded" { didSet { onBackendChanged?(backend) } }
    /// LiteRT-LM's measured speed for the last call ("prefill 772 tok @ 2878 tok/s · decode ..."), for Evidence.
    private(set) var lastSpeed: String?
    /// Speculative decoding (Gemma 4's multi-token-prediction drafter) for the chef's chat turns only: short free
    /// text with no images and no JSON schema. Plans and camera checks keep plain decoding (with the schema the
    /// plan ran to its token limit; with images there is an open LiteRT-LM Metal issue).
    var speculativeChat = false
    func setSpeculativeChat(_ on: Bool) { speculativeChat = on }
    /// LiteRT schema-constrained decoding for JSON tasks. Off by default after a native llguidance abort on
    /// iPhone; on, the schema is enforced token by token instead of being only a prompt contract.
    var constrainedDecoding = false
    func setConstrainedDecoding(_ on: Bool) { constrainedDecoding = on }

    func load(path: String, useGPU: Bool, backendChanged: (@Sendable (String) -> Void)? = nil) async throws -> Double {
        try requireHealthyForeground()
        guard !busy else { throw RunnerError.busy }
        busy = true; defer { busy = false }
        onBackendChanged = backendChanged
        engine = nil
        // LiteRT-LM's per-call prefill/decode speeds are an experimental API; read only for the Evidence screen.
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        // The pinned iPhone runtime aborts in llguidance's tokenizer allocation, before Swift can catch it.
        // JSON remains validated by ChefBrain/RemyCore; never create that native constraint provider.
        ExperimentalFlags.enableConversationConstrainedDecoding = false
        // Native conversation setup still uses its 280-token default even for text-only prefills.
        // Keep that engine capacity; actual image messages below are limited to 140.
        ExperimentalFlags.visualTokenBudget = 280
        let float32Metal = useGPU && ProcessInfo.processInfo.arguments.contains("--fp32-metal")
        let start = ProcessInfo.processInfo.systemUptime
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gemma-v0181-\(URL(fileURLWithPath: path).lastPathComponent)-\(useGPU ? (float32Metal ? "gpu-fp32" : "gpu") : "cpu")", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #if targetEnvironment(simulator)
        // The simulator's Metal cannot build Gemma's GPU kernels; CPU lets prompts be tested on a Mac.
        let useGPU = false
        #endif
        let config = try EngineConfig(modelPath: path, backend: useGPU ? .gpu : .cpu(threadCount: 4),
                                      visionBackend: .cpu(threadCount: 2), audioBackend: .cpu(threadCount: 2),
                                      maxNumTokens: 4096,
                                      cacheDir: cache.path, activationDataType: float32Metal ? .float32 : nil)
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        engine = candidate
        // The image encoder stays on CPU: on iPhone 17 (LiteRT-LM 0.18.1) a GPU vision backend fails to
        // create a conversation ("STABLEHLO_COMPOSITE failed to prepare").
        backend = useGPU ? "Metal GPU\(float32Metal ? " FP32" : "") · vision + audio CPU" : "CPU · vision + audio CPU"
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    /// Free-text call used by the local smoke tests. `structured` runs the board check.
    func run(prompt: String, images: [Data] = [], structured: Bool = false) async throws -> InferenceResult {
        if structured { return try await run(ChefPrompt.board, prompt: prompt, images: images) }
        return try await generate(system: "You are a helpful local cooking assistant. Reply briefly.", schema: nil,
                                  maxTokens: 96, prompt: prompt, images: images, audio: nil)
    }

    /// One structured Gemma call. Audio is a 16 kHz mono WAV of the cook speaking.
    /// `constrained: false` drops the schema enforcement; RemyEval uses it to measure the decoding cost.
    /// `onText` streams the reply so far, for showing a long answer (the recipe plan) while it is written.
    /// `speculative`: this conversation uses speculative decoding (only for text without a schema).
    func run(_ task: GemmaTask, prompt: String, images: [Data] = [], audio: Data? = nil,
             constrained: Bool = true, speculative: Bool = false, onText: (@Sendable (String) -> Void)? = nil) async throws -> InferenceResult {
        try await generate(system: task.system, schema: constrained && !task.schema.isEmpty ? task.schema : nil, maxTokens: task.maxTokens,
                           visualTokens: task.visualTokens, prompt: prompt, images: images, audio: audio, speculative: speculative, onText: onText)
    }

    /// A conversational turn with tools (Gemma 4 function calling). The model may answer, call tools, or both;
    /// the caller carries out the calls. Slightly random (0.3): natural replies, still reliable tool calls.
    func converse(system: String, history: [Message], tools: [Tool], prompt: Message, maxTokens: Int)
        async throws -> (reply: Message, elapsedMS: Double) {
        do { return try await converseOnce(system: system, history: history, tools: tools, prompt: prompt, maxTokens: maxTokens) }
        catch {
            if requiresRestart { throw RunnerError.restartRequired }
            guard Self.needsEngineRecovery(error) else { throw error }
            try await recoverEngine()
            return try await converseOnce(system: system, history: history, tools: tools, prompt: prompt, maxTokens: maxTokens)
        }
    }

    private func converseOnce(system: String, history: [Message], tools: [Tool], prompt: Message, maxTokens: Int)
        async throws -> (reply: Message, elapsedMS: Double) {
        try requireHealthyForeground()
        guard !busy else { throw RunnerError.busy }
        guard let engine else { throw RunnerError.notLoaded }
        busy = true; defer { busy = false }
        let config = ConversationConfig(
            systemMessage: Message(system, role: .system), initialMessages: history, tools: tools,
            samplerConfig: try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.3, seed: 7),
            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0), automaticToolCalling: false, visualTokenBudget: 280,
            enableSpeculativeDecoding: speculativeChat)
        let conversation = try await engine.createConversation(with: config)
        try requireHealthyForeground()
        let start = ProcessInfo.processInfo.systemUptime
        let reply = try await conversation.sendMessageSafely(prompt, maxOutputTokens: maxTokens,
                                                       thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
        if ExperimentalFlags.enableBenchmark, let info = try? conversation.getBenchmarkInfo() {
            lastSpeed = String(format: "prefill %d tok @ %.0f tok/s · decode %d tok @ %.1f tok/s · first token %.2f s",
                               info.lastPrefillTokenCount, info.lastPrefillTokensPerSecond,
                               info.lastDecodeTokenCount, info.lastDecodeTokensPerSecond, info.timeToFirstTokenInSecond)
        }
        return (reply, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// Prompt reuse experiment (RemyEval --clone-bench): each turn as a fresh conversation vs a clone of one
    /// conversation that already holds the system prompt and tools, plus a leak check between sibling clones.
    func cloneBench(system: String, tools: [Tool], prompts: [String]) async throws -> [String] {
        try requireHealthyForeground()
        guard !busy else { throw RunnerError.busy }
        guard let engine else { throw RunnerError.notLoaded }
        busy = true; defer { busy = false }
        let thinking = ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0)
        func config() throws -> ConversationConfig {
            ConversationConfig(systemMessage: Message(system, role: .system), tools: tools,
                               samplerConfig: try SamplerConfig(topK: 1, topP: 0.9, temperature: 0.1, seed: 7),
                               thinkingConfig: thinking, automaticToolCalling: false, visualTokenBudget: 280, enableSpeculativeDecoding: false)
        }
        func stats(_ conversation: Conversation) -> String {
            guard let info = try? conversation.getBenchmarkInfo() else { return "no stats" }
            return String(format: "prefill %d tok, first token %.2f s", info.lastPrefillTokenCount, info.timeToFirstTokenInSecond)
        }
        var lines: [String] = []
        for prompt in prompts {
            let start = ProcessInfo.processInfo.systemUptime
            let fresh = try await engine.createConversation(with: try config())
            try requireHealthyForeground()
            let reply = try await fresh.sendMessageSafely(Message(prompt), maxOutputTokens: 48, thinkingConfig: thinking)
            lines.append(String(format: "fresh  %.0f ms · %@ · %@ → %@", (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                stats(fresh), prompt, reply.toolCalls.first?.name ?? String(reply.toString.prefix(60))))
        }
        let baseStart = ProcessInfo.processInfo.systemUptime
        let base = try await engine.createConversation(with: try config())
        lines.append(String(format: "base conversation created in %.0f ms", (ProcessInfo.processInfo.systemUptime - baseStart) * 1000))
        for prompt in prompts {
            let start = ProcessInfo.processInfo.systemUptime
            try requireHealthyForeground()
            let clone = try base.clone()
            let reply = try await clone.sendMessageSafely(Message(prompt), maxOutputTokens: 48, thinkingConfig: thinking)
            lines.append(String(format: "clone  %.0f ms · %@ · %@ → %@", (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                stats(clone), prompt, reply.toolCalls.first?.name ?? String(reply.toString.prefix(60))))
        }
        // Leak check: a fact told to one clone must not be known to its sibling.
        try requireHealthyForeground()
        let first = try base.clone()
        _ = try await first.sendMessageSafely(Message("Remember this: my dog is called Biscuit. Just say okay."), maxOutputTokens: 16, thinkingConfig: thinking)
        try requireHealthyForeground()
        let second = try base.clone()
        let answer = try await second.sendMessageSafely(Message("What is my dog called? If you do not know, say unknown."), maxOutputTokens: 16, thinkingConfig: thinking)
        lines.append("leak check (sibling clone asked the dog's name): \(answer.toString)")
        return lines
    }

    private func generate(system: String, schema: String?, maxTokens: Int, visualTokens: Int = 280, prompt: String,
                          images: [Data], audio: Data?, speculative: Bool = false,
                          onText: (@Sendable (String) -> Void)? = nil) async throws -> InferenceResult {
        do {
            return try await generateOnce(system: system, schema: schema, maxTokens: maxTokens, visualTokens: visualTokens,
                                          prompt: prompt, images: images, audio: audio, speculative: speculative, onText: onText)
        } catch {
            if requiresRestart { throw RunnerError.restartRequired }
            guard Self.needsEngineRecovery(error) else { throw error }
            try await recoverEngine()
            return try await generateOnce(system: system, schema: schema, maxTokens: maxTokens, visualTokens: visualTokens,
                                          prompt: prompt, images: images, audio: audio, speculative: speculative, onText: onText)
        }
    }

    // A failed native invocation can poison subsequent conversations. Rebuild once, after the failed
    // conversation has released its buffers; never replay app actions or retry validation failures.
    private static func needsEngineRecovery(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return ["failed to invoke the compiled model", "non-persistent memory is not available",
                "failed to lock custom tensor buffer", "tensor buffer is already locked",
                "failed to create custom tensor buffer", "failed to allocate id<mtlbuffer>"].contains { message.contains($0) }
    }
    func rebuildCPUForDeviceRegression() async throws { try await recoverEngine() }

    private func recoverEngine() async throws {
        try requireHealthyForeground()
        guard !busy else { throw RunnerError.busy }
        busy = true; defer { busy = false }
        guard let config = await engine?.engineConfig else { throw RunnerError.notLoaded }
        try requireHealthyForeground()
        engine = nil
        // The failed Metal allocator may retain unusable native buffers. A fresh CPU engine avoids
        // that allocator entirely and leaves all inference on device, at reduced speed.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gemma-v0181-\(URL(fileURLWithPath: config.modelPath).lastPathComponent)-cpu", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let fallback = try EngineConfig(modelPath: config.modelPath, backend: .cpu(threadCount: 4),
                                       visionBackend: .cpu(threadCount: 2), audioBackend: .cpu(threadCount: 2),
                                       maxNumTokens: config.maxNumTokens,
                                       cacheDir: cache.path)
        let candidate = Engine(engineConfig: fallback)
        try await candidate.initialize()
        engine = candidate
        backend = "CPU recovery · vision + audio CPU"
    }

    private func generateOnce(system: String, schema: String?, maxTokens: Int, visualTokens: Int, prompt: String,
                              images: [Data], audio: Data?, speculative: Bool,
                              onText: (@Sendable (String) -> Void)?) async throws -> InferenceResult {
        try requireHealthyForeground()
        guard !busy else { throw RunnerError.busy }
        guard let engine else { throw RunnerError.notLoaded }
        busy = true; defer { busy = false }
        // Keep the schema as a prompt contract. Native llguidance allocation can abort the process on iPhone;
        // decode/validation and the existing bounded retry still decide whether the reply may change state.
        let outputInstruction = schema.map { JSONOutputContract.instruction(schema: $0) } ?? ""
        let systemPrompt = system + outputInstruction
        // Keep one vision signature across glances, ingredient checks and box searches instead
        // of repeatedly changing native tensor shapes. Text-only prefills retain the runtime's
        // 280-token default. This also applies after a CPU recovery.
        let imageBudget = images.isEmpty ? 280 : 140
        let config = ConversationConfig(
            systemMessage: systemPrompt.isEmpty ? nil : Message(systemPrompt, role: .system),
            samplerConfig: try SamplerConfig(topK: 1, topP: 0.9, temperature: 0.1, seed: 7),
            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0),
            automaticToolCalling: false, enableResponseFormat: constrainedDecoding && schema != nil,
            visualTokenBudget: Int32(imageBudget),
            enableSpeculativeDecoding: speculative
        )
        let format = constrainedDecoding ? try schema.map { try ResponseFormat.json(schema: $0) } : nil
        let conversation = try await engine.createConversation(with: config)
        try requireHealthyForeground()
        // Gemma 4's documented order: images before the text, audio after it.
        var contents: [Content] = images.map { .imageData($0) }
        contents.append(.text(prompt))
        if let audio { contents.append(.audioData(audio)) }
        let start = ProcessInfo.processInfo.systemUptime
        let thinking = ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0)
        var text = try await conversation.sendMessageSafely(Message(contents: contents), maxOutputTokens: maxTokens,
                                                            thinkingConfig: thinking, responseFormat: format,
                                                            onText: onText).toString
        if schema != nil { text = JSONOutputContract.clean(text) }
        var result = InferenceResult(text: text, elapsedMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                     imageCount: images.count)
        if ExperimentalFlags.enableBenchmark, let info = try? conversation.getBenchmarkInfo() {
            result.speed = String(format: "prefill %d tok @ %.0f tok/s · decode %d tok @ %.1f tok/s · first token %.2f s",
                                  info.lastPrefillTokenCount, info.lastPrefillTokensPerSecond,
                                  info.lastDecodeTokenCount, info.lastDecodeTokensPerSecond, info.timeToFirstTokenInSecond)
            lastSpeed = result.speed
        }
        return result
    }
}

enum RunnerError: LocalizedError {
    case busy, notLoaded, invalidModel, missingImage, noPlan, inBackground, restartRequired
    var errorDescription: String? {
        switch self {
        case .busy: return "Gemma is still working. Wait for this check to finish."
        case .notLoaded: return "Load Gemma first in Settings."
        case .invalidModel: return "This model does not match the pinned Gemma file. Download or import the correct file."
        case .missingImage: return "Start the camera and give it a moment to capture the board."
        case .noPlan: return "Tell Remy what you want to make first."
        case .inBackground: return "Return to Remy to continue."
        case .restartRequired: return "The local model stopped safely after a runtime error. Close and reopen Remy to restart it."
        }
    }
}
