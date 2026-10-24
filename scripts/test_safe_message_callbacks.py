#!/usr/bin/env python3
"""Compile production Swift callback state with a non-native Conversation fixture.

Exercises parsing, ownership, and completion behavior without a phone/model or network.
The fixture replaces only native Conversation creation; Message/jsonToMessage and all
safe callback state are extracted from the actual vendored files on each run.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Vendor/LiteRTLM/Sources/Conversation.swift").read_text()
message = (ROOT / "Vendor/LiteRTLM/Sources/Message.swift").read_text()
support = source.split("// BEGIN SAFE_REPLY_SUPPORT", 1)[1]
support = support[support.index("\n"):].split("private func safeMessageCallback", 1)[0]
parser = source.split("  public static func jsonToMessage", 1)[1]
parser = "  public static func jsonToMessage" + parser.split("  /// Context object", 1)[0]

fixture = r'''
enum LiteRTLMError: Error {
  enum MessageError { case failedToConvertToJson, invalidContent }
  enum ConversationError { case invalidResponse(String) }
  case message(MessageError), conversation(ConversationError)
}
final class Conversation {
  let onRelease: () -> Void
  init(onRelease: @escaping () -> Void = {}) { self.onRelease = onRelease }
  deinit { onRelease() }
PARSER
}
'''.replace("PARSER", parser)

tests = r'''
func expect(_ condition: @autoclosure () -> Bool, _ text: String) {
  if !condition() { fatalError(text) }
}
final class Counter: @unchecked Sendable {
  let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); count += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class WeakBox {
  weak var conversation: Conversation?
  weak var context: AnyObject?
}
private func sendFixture(_ events: (SafeMessageContext) -> Void, weakBox: WeakBox? = nil,
                 startupError: Error? = nil,
                 onText: (@Sendable (String) -> Void)? = nil) async throws -> Message {
  try await withCheckedThrowingContinuation { continuation in
    let conversation = Conversation()
    let context = SafeMessageContext(conversation: conversation, continuation: continuation, onText: onText)
    weakBox?.conversation = conversation; weakBox?.context = context
    do { try SafeInferenceLifetime.claim(context) }
    catch { continuation.resume(throwing: error); return }
    context.startWatchdog(timeoutSeconds: CommandLine.arguments.contains("timeout") ? 0.02 : 120)
    // Simulate native callbacks arriving before the native start function returns.
    events(context)
    context.startFinished(error: startupError)
  }
}
@main struct Tests {
  static func main() async throws {
    let owner = NSObject()
    try SafeInferenceLifetime.claim(owner)
    do { try SafeInferenceLifetime.claim(NSObject()); fatalError("concurrent claim accepted") }
    catch SafeInferenceFailure.concurrentSend { }
    SafeInferenceLifetime.releaseSuccessful(owner)

    let engineA = NSObject(), engineB = NSObject(), engineC = NSObject()
    let firstOwner = NSObject(), secondOwner = NSObject()
    try SafeInferenceLifetime.claim(firstOwner, engine: engineA)
    do { try SafeInferenceLifetime.claim(NSObject(), engine: engineA); fatalError("same-engine concurrent claim accepted") }
    catch SafeInferenceFailure.concurrentSend { }
    try SafeInferenceLifetime.claim(secondOwner, engine: engineB)
    do { try SafeInferenceLifetime.claim(NSObject(), engine: engineC); fatalError("third native engine accepted") }
    catch SafeInferenceFailure.concurrentSend { }
    SafeInferenceLifetime.releaseSuccessful(firstOwner)
    SafeInferenceLifetime.releaseSuccessful(secondOwner)

    if CommandLine.arguments.contains("dual-failure") {
      final class Owner {
        let conversation = Conversation()
      }
      var a: Owner? = Owner(), b: Owner? = Owner()
      weak var retainedA = a?.conversation
      weak var retainedB = b?.conversation
      try SafeInferenceLifetime.claim(a!, engine: engineA)
      try SafeInferenceLifetime.claim(b!, engine: engineB)
      SafeInferenceLifetime.quarantine(a!); a = nil
      expect(SafeInferenceLifetime.requiresRestart, "first engine failure did not block process")
      SafeInferenceLifetime.quarantine(b!); b = nil
      expect(retainedA != nil && retainedB != nil, "second failure released the first failed native owner")
      do { try SafeInferenceLifetime.claim(NSObject(), engine: engineC); fatalError("new engine accepted after failure") }
      catch SafeInferenceFailure.restartRequired { }
      print("PASS [dual-failure]: independent engine admission; same-engine/third-engine rejection; both failed owners retained; process fails closed")
      return
    }

    let progress = Counter()
    let successfulLifetime = WeakBox()
    let reply = try await sendFixture({ context in
      context.receive(json: #"{"role":"assistant"}"#, error: nil, isFinal: false)
      context.receive(json: #"{"content":[],"tool_calls":[],"channels":{}}"#, error: nil, isFinal: false)
      context.receive(json: #"{"role":"assistant","content":[{"type":"text","text":"Hello"}]}"#, error: nil, isFinal: false)
      context.receive(json: #"{"role":"assistant","content":[{"type":"text","text":" world"}],"channels":{"analysis":"a"}}"#, error: nil, isFinal: false)
      context.receive(json: #"{"channels":{"analysis":"b"}}"#, error: nil, isFinal: false)
      context.receive(json: #"{}"#, error: nil, isFinal: false)
      context.receive(json: nil, error: nil, isFinal: true)
      context.receive(json: nil, error: nil, isFinal: true) // duplicate final: exactly one resume
    }, weakBox: successfulLifetime, onText: { _ in progress.increment() })
    expect(reply.toString == "Hello world", "delta text acquired extra spaces")
    expect(reply.channels["analysis"] == "ab", "channel deltas lost")
    expect(progress.value == 3, "cumulative text callback count")
    expect(successfulLifetime.conversation == nil, "successful context retained native conversation")

    let empty = try await sendFixture { context in
      context.receive(json: #"{"role":"assistant","content":[],"tool_calls":[],"channels":{}}"#, error: nil, isFinal: false)
      context.receive(json: nil, error: nil, isFinal: true)
    }
    expect(empty.toString.isEmpty && empty.toolCalls.isEmpty, "clean empty completion was not preserved")
    expect(!SafeInferenceLifetime.requiresRestart, "valid empty delta quarantined runtime")

    let tools = try await sendFixture { context in
      context.receive(json: #"{"role":"assistant","tool_calls":[{"id":"one","type":"function","function":{"name":"next_step","arguments":{}}}]}"#, error: nil, isFinal: false)
      context.receive(json: #"{"tool_calls":[{"id":"two","function":{"name":"look","arguments":{"question":"what is here?"}}}]}"#, error: nil, isFinal: false)
      context.receive(json: nil, error: nil, isFinal: true)
    }
    expect(tools.toString.isEmpty, "tool-only response gained text")
    expect(tools.toolCalls.map(\.name) == ["next_step", "look"], "tool-only calls lost or reordered")
    expect(tools.toolCalls[1].arguments["question"] as? String == "what is here?", "tool arguments lost")
    expect(!SafeInferenceLifetime.requiresRestart, "successful callbacks quarantined")

    let weakBox = WeakBox()
    do {
      _ = try await sendFixture({ context in
        context.receive(json: #"{"content":[{"type":"text","text":"partial"}]}"#, error: nil, isFinal: false)
        if CommandLine.arguments.contains("timeout") { return }
        if CommandLine.arguments.contains("startup-error") {
          context.receive(json: nil, error: nil, isFinal: true)
          return
        }
        if CommandLine.arguments.contains("native-error") {
          // Pinned C wrapper calls an error "final", even for a processing parse error.
          context.receive(json: nil, error: "native processing parse error", isFinal: true)
        } else {
          context.receive(json: "{broken JSON", error: nil, isFinal: false)
        }
        context.receive(json: #"{"content":[{"type":"text","text":"late"}]}"#, error: nil, isFinal: false)
        context.receive(json: nil, error: nil, isFinal: true)
      }, weakBox: weakBox,
         startupError: CommandLine.arguments.contains("startup-error") ? SafeInferenceFailure.malformedChunk : nil)
      fatalError("failed callback unexpectedly succeeded")
    } catch {
      if CommandLine.arguments.contains("timeout") {
        guard case SafeInferenceFailure.timedOut = error else { fatalError("timeout returned the wrong error") }
      }
    }
    expect(SafeInferenceLifetime.requiresRestart, "failure did not fail closed")
    expect(weakBox.context != nil, "callback data released after parse error")
    expect(weakBox.conversation != nil, "native conversation released after parse error")
    do { try SafeInferenceLifetime.claim(NSObject()); fatalError("new inference after quarantine") }
    catch SafeInferenceFailure.restartRequired { }
    // After the awaiting task has unwound, late callbacks still have a valid context and no continuation.
    (weakBox.context as? SafeMessageContext)?.receive(json: nil, error: "later error", isFinal: true)
    (weakBox.context as? SafeMessageContext)?.receive(json: nil, error: nil, isFinal: true)
    expect(weakBox.conversation != nil, "late callback released quarantined engine")
    print("PASS [\(CommandLine.arguments.dropFirst().first ?? "parse-error")]: real parser; text/channels; manual tool-only calls; startup callbacks; duplicate completion; success release; bounded error/timeout quarantine")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="safe-callback-", dir=Path(__file__).parent) as temporary:
    p = Path(temporary)
    swift = p / "SafeCallbackTests.swift"
    swift.write_text("import Foundation\n" + message + fixture + support + tests)
    binary = p / "safe-callback-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    subprocess.run([str(binary), "native-error"], check=True)
    subprocess.run([str(binary), "timeout"], check=True)
    subprocess.run([str(binary), "startup-error"], check=True)
    subprocess.run([str(binary), "dual-failure"], check=True)
