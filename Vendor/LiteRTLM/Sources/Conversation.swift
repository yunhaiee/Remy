// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import OSLog
import CLiteRTLM

extension ResponseFormat.FormatType {
  var cConstraintType: LiteRtLmConstraintType {
    switch self {
    case .regex:
      return kLiteRtLmConstraintTypeRegex
    case .jsonObject:
      return kLiteRtLmConstraintTypeJsonSchema
    }
  }
}

typealias CConversationHandle = OpaquePointer

private let logger = Logger(
  subsystem: "com.google.odml.litertlm.swift",
  category: "Conversation"
)

private let recurringToolCallLimit = 25

/// Represents a conversation with the LiteRT-LM model.
///
/// Example usage:
/// ```swift
/// // Assuming 'engine' is an instance of Engine
/// let conversation = try await engine.createConversation()
///
/// // Send a message and get the response.
/// let response = try conversation.sendMessage(Message("Hello world"))
///
/// // Send a message async with response chunks as AsyncThrowingStream.
/// for try await chunk in conversation.sendMessageStream(Message("Hello world")) {
///   print(chunk.text)
/// }
/// ```
///
/// This class facilitates interaction with the LiteRT-LM model by handling message sending
/// and response reception.
public final class Conversation: Sendable {
  private let logger = Logger(
    subsystem: "com.google.ai.edge.litertlm.swift",
    category: "Conversation"
  )

  private let handle: CConversationHandle?
  private let toolManager: ToolManager
  private let automaticToolCalling: Bool
  private let engine: Engine
  private let enableResponseFormat: Bool
  private let visualTokenBudget: Int32?

  /// Whether the conversation is alive and ready to be used.
  public var isAlive: Bool {
    return handle != nil
  }

  init(
    handle: CConversationHandle, toolManager: ToolManager, automaticToolCalling: Bool = true,
    engine: Engine, enableResponseFormat: Bool = false, visualTokenBudget: Int32? = nil
  ) {
    self.handle = handle
    self.toolManager = toolManager
    self.automaticToolCalling = automaticToolCalling
    self.engine = engine
    self.enableResponseFormat = enableResponseFormat
    self.visualTokenBudget = visualTokenBudget
  }

  deinit {
    if let handle = handle {
      litert_lm_conversation_delete(handle)
    }
  }

  /// Duplicates this conversation with its prefilled state (C API `litert_lm_conversation_clone`).
  /// Backported by Remy: upstream LiteRT-LM main added `Conversation.clone()` after the v0.18.1 release.
  public func clone() throws -> Conversation {
    let handle = try checkIsAlive()
    guard let cloned = litert_lm_conversation_clone(handle) else {
      throw LiteRTLMError.conversation(.invalidResponse(LiteRTLMError.consumeLastError() ?? "clone failed"))
    }
    return Conversation(
      handle: cloned, toolManager: toolManager, automaticToolCalling: automaticToolCalling, engine: engine,
      enableResponseFormat: enableResponseFormat, visualTokenBudget: visualTokenBudget)
  }

  private func shouldApplyResponseFormat(
    _ responseFormat: ResponseFormat?,
    forMessageDict messageDict: [String: Any]
  ) -> Bool {
    guard responseFormat != nil else { return false }
    let isToolResponse = (messageDict["role"] as? String) == "tool"
    if automaticToolCalling && toolManager.toolsJsonDescription != "[]" && !isToolResponse {
      return false
    }
    return true
  }

  /// Sends a message to the model and returns the response. This is a synchronous call.
  ///
  /// - Parameter message: The message to send to the model.
  /// - Parameter extraContext: The extra context to send to the model.
  /// - Parameter repetitionPenaltyConfig: Optional configuration for repetition penalty.
  /// - Parameter noRepeatNgramConfig: Optional configuration for no repeat ngram penalty.
  /// - Parameter maxOutputTokens: Optional maximum number of tokens to generate per response. For thinking models, both thinking (reasoning) tokens and the final response tokens count towards this limit.
  /// - Parameter thinkingConfig: Optional configuration for thinking/reasoning generation.
  /// - Parameter responseFormat: Optional response format for constrained decoding.
  /// - Returns: The model's response message.
  /// - Throws: A `LiteRTLMError` if sending the message fails or the model
  ///   returns an invalid response.
  public func sendMessage(
    _ message: Message,
    extraContext: [String: Any]? = nil,
    repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
    noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
    suppressTokensConfig: SuppressTokensConfig? = nil,
    maxOutputTokens: Int? = nil,
    thinkingConfig: ThinkingConfig? = nil,
    responseFormat: ResponseFormat? = nil
  ) async throws -> Message {
    let handle = try checkIsAlive()

    if responseFormat != nil && !enableResponseFormat {
      throw LiteRTLMError.conversation(.responseFormatNotEnabled)
    }

    var currentMessageJson: [String: Any] = message.toJson

    for i in 0..<recurringToolCallLimit {
      let (responseJson, responseString) = try attemptSendMessage(
        handle: handle,
        messageJson: currentMessageJson,
        extraContext: extraContext,
        repetitionPenaltyConfig: repetitionPenaltyConfig,
        noRepeatNgramConfig: noRepeatNgramConfig,
        suppressTokensConfig: suppressTokensConfig,
        maxOutputTokens: maxOutputTokens,
        thinkingConfig: i == 0 ? thinkingConfig : nil,
        responseFormat: responseFormat
      )

      guard let toolCalls = responseJson["tool_calls"] as? [[String: Any]] else {
        if responseJson["content"] != nil || responseJson["channels"] != nil {
          return try Conversation.jsonToMessage(responseString)
        } else {
          throw LiteRTLMError.conversation(.invalidResponse(responseString))
        }
      }
      if !automaticToolCalling {
        return try Conversation.jsonToMessage(responseString)
      }
      currentMessageJson = try await handleToolCalls(toolCalls)
    }
    throw LiteRTLMError.conversation(
      .recurringToolCallLimitExceeded(limit: recurringToolCallLimit))
  }

  /// Whether a failed native callback requires restarting the process before more inference.
  /// The pinned C API cannot prove that an error callback was the last callback. Its conversation
  /// and engine are retained rather than destroyed while native work might still reference them.
  public static var safeInferenceRequiresRestart: Bool { SafeInferenceLifetime.requiresRestart }

  /// Receives a complete response through the native asynchronous API, without executing tools.
  /// Unlike sendMessage, this avoids the pinned native synchronous wait's timeout/teardown path.
  /// A task cancellation does not destroy or release native work; completion still owns its lifetime.
  public func sendMessageSafely(
    _ message: Message,
    extraContext: [String: Any]? = nil,
    repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
    noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
    suppressTokensConfig: SuppressTokensConfig? = nil,
    maxOutputTokens: Int? = nil,
    thinkingConfig: ThinkingConfig? = nil,
    responseFormat: ResponseFormat? = nil,
    onText: (@Sendable (String) -> Void)? = nil
  ) async throws -> Message {
    guard !automaticToolCalling else {
      throw SafeInferenceFailure.manualToolsRequired
    }
    let handle = try checkIsAlive()
    if responseFormat != nil && !enableResponseFormat {
      throw LiteRTLMError.conversation(.responseFormatNotEnabled)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let context = SafeMessageContext(conversation: self, continuation: continuation, onText: onText)
      do {
        // Claim before entering C: even a callback delivered synchronously during startup has an owner.
        try SafeInferenceLifetime.claim(context, engine: engine)
        context.startWatchdog()
      } catch {
        continuation.resume(throwing: error)
        return
      }
      do {
        try sendNativeStream(
          handle: handle, messageJson: message.toJson, extraContext: extraContext,
          repetitionPenaltyConfig: repetitionPenaltyConfig,
          noRepeatNgramConfig: noRepeatNgramConfig, suppressTokensConfig: suppressTokensConfig,
          maxOutputTokens: maxOutputTokens, thinkingConfig: thinkingConfig,
          responseFormat: responseFormat, callback: safeMessageCallback,
          contextPtr: Unmanaged.passUnretained(context).toOpaque())
        context.startFinished(error: nil)
      } catch {
        // A native start error can occur after work has been scheduled. Fail closed even here.
        context.startFinished(error: error)
      }
    }
  }

  private func attemptSendMessage(
    handle: CConversationHandle,
    messageJson: [String: Any],
    extraContext: [String: Any]?,
    repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
    noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
    suppressTokensConfig: SuppressTokensConfig? = nil,
    maxOutputTokens: Int? = nil,
    thinkingConfig: ThinkingConfig? = nil,
    responseFormat: ResponseFormat? = nil
  ) throws
    -> (responseJson: [String: Any], responseString: String)
  {
    let messageData = try JSONSerialization.data(withJSONObject: messageJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    var extraContextString: String? = nil
    if let extraContext = extraContext, !extraContext.isEmpty,
      let extraData = try? JSONSerialization.data(withJSONObject: extraContext)
    {
      extraContextString = String(data: extraData, encoding: .utf8)
    }
    let optionalArgs = litert_lm_conversation_optional_args_create()
    defer { litert_lm_conversation_optional_args_delete(optionalArgs) }
    if let visualTokenBudget = self.visualTokenBudget ?? ExperimentalFlags.visualTokenBudget {
      litert_lm_conversation_optional_args_set_visual_token_budget(
        optionalArgs, Int32(visualTokenBudget))
    }
    if let repetitionPenaltyConfig = repetitionPenaltyConfig {
      guard let cRepetitionPenaltyConfig = litert_lm_repetition_penalty_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError()
          ?? "Failed to create native repetition penalty config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_repetition_penalty_config_delete(cRepetitionPenaltyConfig) }

      if let repetitionPenalty = repetitionPenaltyConfig.repetitionPenalty {
        litert_lm_repetition_penalty_config_set_repetition_penalty(
          cRepetitionPenaltyConfig, repetitionPenalty)
      }
      if let presencePenalty = repetitionPenaltyConfig.presencePenalty {
        litert_lm_repetition_penalty_config_set_presence_penalty(
          cRepetitionPenaltyConfig, presencePenalty)
      }
      if let frequencyPenalty = repetitionPenaltyConfig.frequencyPenalty {
        litert_lm_repetition_penalty_config_set_frequency_penalty(
          cRepetitionPenaltyConfig, frequencyPenalty)
      }
      if let windowSize = repetitionPenaltyConfig.windowSize {
        litert_lm_repetition_penalty_config_set_window_size(
          cRepetitionPenaltyConfig, Int32(windowSize))
      }
      litert_lm_conversation_optional_args_set_repetition_penalty_config(
        optionalArgs, cRepetitionPenaltyConfig)
    }
    if let noRepeatNgramConfig = noRepeatNgramConfig {
      guard let cNoRepeatNgramConfig = litert_lm_no_repeat_ngram_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native no repeat ngram config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_no_repeat_ngram_config_delete(cNoRepeatNgramConfig) }

      if let noRepeatNgramSize = noRepeatNgramConfig.noRepeatNgramSize {
        litert_lm_no_repeat_ngram_config_set_no_repeat_ngram_size(
          cNoRepeatNgramConfig, Int32(noRepeatNgramSize))
      }
      if let windowSize = noRepeatNgramConfig.windowSize {
        litert_lm_no_repeat_ngram_config_set_window_size(
          cNoRepeatNgramConfig, Int32(windowSize))
      }
      litert_lm_conversation_optional_args_set_no_repeat_ngram_config(
        optionalArgs, cNoRepeatNgramConfig)
    }
    if let suppressTokens = suppressTokensConfig?.suppressTokens, !suppressTokens.isEmpty {
      guard let cSuppressTokensConfig = litert_lm_suppress_tokens_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native suppress tokens config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_suppress_tokens_config_delete(cSuppressTokensConfig) }

      let cTokens = suppressTokens.map { Int32($0) }
      cTokens.withUnsafeBufferPointer { buffer in
        litert_lm_suppress_tokens_config_set_suppress_tokens(
          cSuppressTokensConfig, buffer.baseAddress, buffer.count)
      }
      litert_lm_conversation_optional_args_set_suppress_tokens_config(
        optionalArgs, cSuppressTokensConfig)
    }
    if let maxOutputTokens = maxOutputTokens {
      litert_lm_conversation_optional_args_set_max_output_tokens(
        optionalArgs, Int32(maxOutputTokens))
    }
    if let thinkingConfig = thinkingConfig {
      guard let cThinkingConfig = litert_lm_thinking_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native thinking config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_thinking_config_delete(cThinkingConfig) }
      litert_lm_thinking_config_set_enable_thinking(
        cThinkingConfig, thinkingConfig.enableThinking)
      litert_lm_thinking_config_set_thinking_token_budget(
        cThinkingConfig, Int32(thinkingConfig.thinkingTokenBudget))
      litert_lm_conversation_optional_args_set_thinking_config(optionalArgs, cThinkingConfig)
    }

    if let responseFormat = responseFormat,
      shouldApplyResponseFormat(responseFormat, forMessageDict: messageJson)
    {
      litert_lm_conversation_optional_args_set_constraint(
        optionalArgs, responseFormat.type.cConstraintType, responseFormat.schemaOrPattern)
    }

    guard
      let responsePtr = litert_lm_conversation_send_message(
        handle, messageString, extraContextString, optionalArgs)
    else {
      let errorMsg = LiteRTLMError.consumeLastError() ?? "Native sendMessage returned null."
      throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
    }
    // Delete the response pointer at the end of each iteration. Handled by defer block.
    let responsePtrRef = responsePtr
    defer { litert_lm_json_response_delete(responsePtrRef) }

    guard let responseChars = litert_lm_json_response_get_string(responsePtr) else {
      let errorMsg =
        LiteRTLMError.consumeLastError() ?? "Native get string for response returned null."
      throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
    }
    let responseString = String(cString: responseChars)

    guard let responseData = responseString.data(using: .utf8),
      let responseJson = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw LiteRTLMError.conversation(.invalidJson("Failed to parse native response JSON."))
    }
    return (responseJson, responseString)
  }

  fileprivate func handleToolCalls(_ toolCalls: [[String: Any]]) async throws -> [String: Any] {
    var toolResponses: [[String: Any]] = []

    for toolCall in toolCalls {
      guard let function = toolCall["function"] as? [String: Any],
        let name = function["name"] as? String,
        let argsObject = function["arguments"] as? [String: Any]
      else {
        continue
      }
      do {
        let result = try await toolManager.execute(name: name, arguments: argsObject)

        toolResponses.append([
          "type": "tool_response",
          "name": name,
          "response": result,
        ])
      } catch {
        throw LiteRTLMError.conversation(.toolExecutionError(name: name, error: "\(error)"))
      }
    }

    return ["role": "tool", "content": toolResponses]
  }

  /// Throws an error if the conversation is not alive.
  ///
  /// - Returns: The `OpaquePointer` handle if the conversation is alive.
  /// - Throws: A `LiteRTLMError` if `handle` is nil, indicating the conversation is not alive.
  fileprivate func checkIsAlive() throws -> OpaquePointer {
    guard let handle else {
      throw LiteRTLMError.conversation(.notAlive)
    }
    return handle
  }

  /// Sends a message to the model and returns an async stream of response chunks.
  ///
  /// - Parameter message: The message to send.
  /// - Parameter extraContext: The extra context to send to the model.
  /// - Parameter repetitionPenaltyConfig: Optional configuration for repetition penalty.
  /// - Parameter maxOutputTokens: Optional maximum number of tokens to generate per response. For thinking models, both thinking (reasoning) tokens and the final response tokens count towards this limit.
  /// - Parameter thinkingConfig: Optional configuration for thinking/reasoning generation.
  /// - Parameter responseFormat: Optional response format for constrained decoding.
  /// - Returns: An async throwing stream of `Message` chunks.
  public func sendMessageStream(
    _ message: Message,
    extraContext: [String: Any]? = nil,
    repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
    noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
    suppressTokensConfig: SuppressTokensConfig? = nil,
    maxOutputTokens: Int? = nil,
    thinkingConfig: ThinkingConfig? = nil,
    responseFormat: ResponseFormat? = nil
  ) -> AsyncThrowingStream<Message, Error> {
    return AsyncThrowingStream { continuation in
      do {
        if responseFormat != nil && !enableResponseFormat {
          throw LiteRTLMError.conversation(.responseFormatNotEnabled)
        }
        let handle = try self.checkIsAlive()
        let messageJson: [String: Any] = message.toJson
        let context = StreamContext(
          continuation: continuation,
          conversation: self,
          repetitionPenaltyConfig: repetitionPenaltyConfig,
          noRepeatNgramConfig: noRepeatNgramConfig,
          suppressTokensConfig: suppressTokensConfig,
          maxOutputTokens: maxOutputTokens,
          responseFormat: responseFormat
        )

        try self.sendToStream(
          handle: handle,
          messageJson: messageJson,
          extraContext: extraContext,
          repetitionPenaltyConfig: repetitionPenaltyConfig,
          noRepeatNgramConfig: noRepeatNgramConfig,
          suppressTokensConfig: suppressTokensConfig,
          maxOutputTokens: maxOutputTokens,
          thinkingConfig: thinkingConfig,
          responseFormat: responseFormat,
          context: context
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  /// Sends a message to the model and handles the response via a streaming callback.
  ///
  /// This function is used internally by `sendMessageStream` and for handling
  /// subsequent tool call responses within the stream.
  ///
  /// - Parameters:
  ///   - handle: The `CConversationHandle` for the current conversation.
  ///   - messageJson: The message to send, represented as a JSON dictionary.
  ///   - extraContext: The extra context to send to the model.
  ///   - repetitionPenaltyConfig: Optional configuration for repetition penalty.
  ///   - thinkingConfig: Optional configuration for thinking/reasoning generation.
  ///   - maxOutputTokens: Optional maximum number of output tokens.
  ///   - context: The `StreamContext` containing the `AsyncThrowingStream.Continuation`
  ///     and other state for the streaming process.
  /// - Throws: A `LiteRTLMError` if the message fails to send or the response is invalid.
  ///   native `send_message_stream` call fails.
  func sendToStream(
    handle: CConversationHandle,
    messageJson: [String: Any],
    extraContext: [String: Any]? = nil,
    repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
    noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
    suppressTokensConfig: SuppressTokensConfig? = nil,
    maxOutputTokens: Int? = nil,
    thinkingConfig: ThinkingConfig? = nil,
    responseFormat: ResponseFormat? = nil,
    context: StreamContext
  ) throws {
    let contextPtr = Unmanaged.passRetained(context).toOpaque()
    do {
      try sendNativeStream(
        handle: handle, messageJson: messageJson, extraContext: extraContext,
        repetitionPenaltyConfig: repetitionPenaltyConfig,
        noRepeatNgramConfig: noRepeatNgramConfig, suppressTokensConfig: suppressTokensConfig,
        maxOutputTokens: maxOutputTokens, thinkingConfig: thinkingConfig,
        responseFormat: responseFormat, callback: streamCallback, contextPtr: contextPtr)
    } catch {
      Unmanaged<StreamContext>.fromOpaque(contextPtr).release()
      throw error
    }
  }

  private func sendNativeStream(
    handle: CConversationHandle,
    messageJson: [String: Any],
    extraContext: [String: Any]?,
    repetitionPenaltyConfig: RepetitionPenaltyConfig?,
    noRepeatNgramConfig: NoRepeatNgramConfig?,
    suppressTokensConfig: SuppressTokensConfig?,
    maxOutputTokens: Int?,
    thinkingConfig: ThinkingConfig?,
    responseFormat: ResponseFormat?,
    callback: LiteRtLmStreamCallback,
    contextPtr: UnsafeMutableRawPointer
  ) throws {
    let messageData = try JSONSerialization.data(withJSONObject: messageJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    var extraContextString: String? = nil
    if let extraContext = extraContext, !extraContext.isEmpty,
      let extraData = try? JSONSerialization.data(withJSONObject: extraContext)
    {
      extraContextString = String(data: extraData, encoding: .utf8)
    }

    let optionalArgs = litert_lm_conversation_optional_args_create()
    defer { litert_lm_conversation_optional_args_delete(optionalArgs) }
    if let visualTokenBudget = self.visualTokenBudget ?? ExperimentalFlags.visualTokenBudget {
      litert_lm_conversation_optional_args_set_visual_token_budget(
        optionalArgs, Int32(visualTokenBudget))
    }
    if let repetitionPenaltyConfig = repetitionPenaltyConfig {
      guard let cRepetitionPenaltyConfig = litert_lm_repetition_penalty_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError()
          ?? "Failed to create native repetition penalty config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_repetition_penalty_config_delete(cRepetitionPenaltyConfig) }

      if let repetitionPenalty = repetitionPenaltyConfig.repetitionPenalty {
        litert_lm_repetition_penalty_config_set_repetition_penalty(
          cRepetitionPenaltyConfig, repetitionPenalty)
      }
      if let presencePenalty = repetitionPenaltyConfig.presencePenalty {
        litert_lm_repetition_penalty_config_set_presence_penalty(
          cRepetitionPenaltyConfig, presencePenalty)
      }
      if let frequencyPenalty = repetitionPenaltyConfig.frequencyPenalty {
        litert_lm_repetition_penalty_config_set_frequency_penalty(
          cRepetitionPenaltyConfig, frequencyPenalty)
      }
      if let windowSize = repetitionPenaltyConfig.windowSize {
        litert_lm_repetition_penalty_config_set_window_size(
          cRepetitionPenaltyConfig, Int32(windowSize))
      }
      litert_lm_conversation_optional_args_set_repetition_penalty_config(
        optionalArgs, cRepetitionPenaltyConfig)
    }
    if let noRepeatNgramConfig = noRepeatNgramConfig {
      guard let cNoRepeatNgramConfig = litert_lm_no_repeat_ngram_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native no repeat ngram config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_no_repeat_ngram_config_delete(cNoRepeatNgramConfig) }

      if let noRepeatNgramSize = noRepeatNgramConfig.noRepeatNgramSize {
        litert_lm_no_repeat_ngram_config_set_no_repeat_ngram_size(
          cNoRepeatNgramConfig, Int32(noRepeatNgramSize))
      }
      if let windowSize = noRepeatNgramConfig.windowSize {
        litert_lm_no_repeat_ngram_config_set_window_size(
          cNoRepeatNgramConfig, Int32(windowSize))
      }
      litert_lm_conversation_optional_args_set_no_repeat_ngram_config(
        optionalArgs, cNoRepeatNgramConfig)
    }
    if let suppressTokens = suppressTokensConfig?.suppressTokens, !suppressTokens.isEmpty {
      guard let cSuppressTokensConfig = litert_lm_suppress_tokens_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native suppress tokens config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_suppress_tokens_config_delete(cSuppressTokensConfig) }

      let cTokens = suppressTokens.map { Int32($0) }
      cTokens.withUnsafeBufferPointer { buffer in
        litert_lm_suppress_tokens_config_set_suppress_tokens(
          cSuppressTokensConfig, buffer.baseAddress, buffer.count)
      }
      litert_lm_conversation_optional_args_set_suppress_tokens_config(
        optionalArgs, cSuppressTokensConfig)
    }
    if let maxOutputTokens = maxOutputTokens {
      litert_lm_conversation_optional_args_set_max_output_tokens(
        optionalArgs, Int32(maxOutputTokens))
    }
    if let thinkingConfig = thinkingConfig {
      guard let cThinkingConfig = litert_lm_thinking_config_create() else {
        let errorMsg =
          LiteRTLMError.consumeLastError() ?? "Failed to create native thinking config."
        throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
      }
      defer { litert_lm_thinking_config_delete(cThinkingConfig) }
      litert_lm_thinking_config_set_enable_thinking(
        cThinkingConfig, thinkingConfig.enableThinking)
      litert_lm_thinking_config_set_thinking_token_budget(
        cThinkingConfig, Int32(thinkingConfig.thinkingTokenBudget))
      litert_lm_conversation_optional_args_set_thinking_config(optionalArgs, cThinkingConfig)
    }

    if let responseFormat = responseFormat,
      shouldApplyResponseFormat(responseFormat, forMessageDict: messageJson)
    {
      litert_lm_conversation_optional_args_set_constraint(
        optionalArgs, responseFormat.type.cConstraintType, responseFormat.schemaOrPattern)
    }

    let status = litert_lm_conversation_send_message_stream(
      handle,
      messageString,
      extraContextString,
      optionalArgs,
      callback,
      contextPtr
    )

    guard status == 0 else {
      let errorMsg = LiteRTLMError.consumeLastError() ?? ""
      throw LiteRTLMError.conversation(.failedToStartStream(status: Int(status), message: errorMsg))
    }
  }

  /// Cancels the ongoing asynchronous inference process.
  public func cancel() throws {
    let handle = try checkIsAlive()
    litert_lm_conversation_cancel_process(handle)
  }

  /// Renders the message into a string for testing and logging.
  ///
  /// This function does not need to be called for actual message sending, as the `sendMessage` and
  /// `sendMessageStream` functions will handle rendering internally.
  ///
  /// - Parameter message: The message to render.
  /// - Returns: The rendered message string.
  /// - Throws: A `LiteRTLMError` if the conversation is not alive, serializing fails, or rendering fails.
  public func renderMessageIntoString(_ message: Message) throws -> String {
    let handle = try checkIsAlive()
    let messageData = try JSONSerialization.data(withJSONObject: message.toJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    guard let cString = litert_lm_conversation_render_message_to_string(handle, messageString)
    else {
      let errorMsg =
        LiteRTLMError.consumeLastError() ?? "Failed to render message into string."
      throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
    }
    return String(cString: cString)
  }

  /// Renders the preface into a string for testing and logging.
  ///
  /// - Returns: The rendered preface string.
  /// - Throws: A `LiteRTLMError` if the conversation is not alive, or rendering fails.
  public func renderPrefaceIntoString() throws -> String {
    let handle = try checkIsAlive()
    guard let cString = litert_lm_conversation_render_preface_to_string(handle) else {
      let errorMsg =
        LiteRTLMError.consumeLastError() ?? "Failed to render preface into string."
      throw LiteRTLMError.conversation(.invalidResponse(errorMsg))
    }
    return String(cString: cString)
  }

  /// Gets the number of tokens in the conversation KV Cache (prefill + decode).
  ///
  /// - Throws: A `LiteRTLMError` if the conversation is not alive.
  public func getTokenCount() throws -> Int {
    let handle = try checkIsAlive()
    return Int(litert_lm_conversation_get_token_count(handle))
  }

  /// Retrieves the benchmark information from the conversation.
  ///
  /// - Returns: The benchmark information
  /// - Throws: A `LiteRTLMError` if the benchmark flag is not enabled or info is unavailable.
  public func getBenchmarkInfo() throws -> BenchmarkInfo {
    let handle = try checkIsAlive()

    if !ExperimentalFlags.enableBenchmark {
      throw LiteRTLMError.conversation(.benchmarkNotEnabled)
    }

    guard let benchmarkInfoPtr = litert_lm_conversation_get_benchmark_info(handle) else {
      throw LiteRTLMError.conversation(.benchmarkInfoUnavailable)
    }
    defer { litert_lm_benchmark_info_delete(benchmarkInfoPtr) }

    let numPrefillTurns = litert_lm_benchmark_info_get_num_prefill_turns(benchmarkInfoPtr)
    let numDecodeTurns = litert_lm_benchmark_info_get_num_decode_turns(benchmarkInfoPtr)

    let initTimeInSecond = litert_lm_benchmark_info_get_total_init_time_in_second(benchmarkInfoPtr)
    let timeToFirstTokenInSecond = litert_lm_benchmark_info_get_time_to_first_token(
      benchmarkInfoPtr)

    let lastPrefillTokenCount: Int =
      numPrefillTurns > 0
      ? Int(
        litert_lm_benchmark_info_get_prefill_token_count_at(
          benchmarkInfoPtr, numPrefillTurns - 1)) : 0
    let lastPrefillTokensPerSec: Double =
      numPrefillTurns > 0
      ? litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(
        benchmarkInfoPtr, numPrefillTurns - 1) : 0.0

    let lastDecodeTokenCount: Int =
      numDecodeTurns > 0
      ? Int(
        litert_lm_benchmark_info_get_decode_token_count_at(
          benchmarkInfoPtr, numDecodeTurns - 1)) : 0
    let lastDecodeTokensPerSec: Double =
      numDecodeTurns > 0
      ? litert_lm_benchmark_info_get_decode_tokens_per_sec_at(
        benchmarkInfoPtr, numDecodeTurns - 1) : 0.0

    return BenchmarkInfo(
      initTimeInSecond: initTimeInSecond,
      timeToFirstTokenInSecond: timeToFirstTokenInSecond,
      lastPrefillTokenCount: lastPrefillTokenCount,
      lastDecodeTokenCount: lastDecodeTokenCount,
      lastPrefillTokensPerSecond: lastPrefillTokensPerSec,
      lastDecodeTokensPerSecond: lastDecodeTokensPerSec
    )
  }

  /// Internal Helper Function to convert a JSON string to a `Message`.
  ///
  /// - Parameter jsonString: The JSON string to convert.
  /// - Returns: The `Message` representation of the JSON string.
  /// - Throws: `LiteRTLMError` if the JSON string is invalid.
  public static func jsonToMessage(_ jsonString: String) throws -> Message {
    guard let data = jsonString.data(using: .utf8),
      let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw LiteRTLMError.message(.failedToConvertToJson)
    }

    var contents: [Content] = []
    if let contentArray = jsonObject["content"] as? [[String: Any]] {
      for item in contentArray {
        if let type = item["type"] as? String {
          switch type {
          case "text":
            if let text = item["text"] as? String {
              contents.append(.text(text))
            }
          case "tool_response":
            if let name = item["name"] as? String, let response = item["response"] {
              let id = item["id"] as? String ?? ""
              contents.append(.toolResponse(name: name, response: response, id: id))
            }
          case "image":
            if let path = item["path"] as? String {
              contents.append(.imageFile(path))
            } else if let blob = item["blob"] as? String, let data = Data(base64Encoded: blob) {
              contents.append(.imageData(data))
            }
          case "audio":
            if let path = item["path"] as? String {
              contents.append(.audioFile(path))
            } else if let blob = item["blob"] as? String, let data = Data(base64Encoded: blob) {
              contents.append(.audioData(data))
            }
          default: break
          }
        }
      }
    }

    var channels: [String: String] = [:]
    if let channelsDict = jsonObject["channels"] as? [String: Any] {
      for (key, value) in channelsDict {
        if let strValue = value as? String {
          channels[key] = strValue
        }
      }
    }

    var toolCalls: [ToolCall] = []
    if let toolCallsArray = jsonObject["tool_calls"] as? [[String: Any]] {
      for item in toolCallsArray {
        if let function = item["function"] as? [String: Any],
          let name = function["name"] as? String,
          let args = function["arguments"] as? [String: Any]
        {
          let id = item["id"] as? String ?? ""
          toolCalls.append(ToolCall(name: name, id: id, arguments: args))
        }
      }
    }

    if contents.isEmpty && channels.isEmpty && toolCalls.isEmpty {
      throw LiteRTLMError.message(.invalidContent)
    }

    let roleRaw = jsonObject["role"] as? String ?? "user"
    let role: Role
    switch roleRaw {
    case "assistant", "model":
      role = .model
    default:
      role = Role(rawValue: roleRaw) ?? .user
    }

    return Message(
      contents: Contents(contents: contents),
      role: role,
      channels: channels,
      toolCalls: toolCalls
    )
  }

  /// Context object to bridge the C callback to the Swift AsyncThrowingStream.
  class StreamContext {
    let continuation: AsyncThrowingStream<Message, Error>.Continuation
    let conversation: Conversation
    var toolCallCount: Int = 0
    var pendingToolCalls: [[String: Any]] = []
    let repetitionPenaltyConfig: RepetitionPenaltyConfig?
    let noRepeatNgramConfig: NoRepeatNgramConfig?
    let suppressTokensConfig: SuppressTokensConfig?
    let maxOutputTokens: Int?
    let responseFormat: ResponseFormat?

    init(
      continuation: AsyncThrowingStream<Message, Error>.Continuation,
      conversation: Conversation,
      repetitionPenaltyConfig: RepetitionPenaltyConfig? = nil,
      noRepeatNgramConfig: NoRepeatNgramConfig? = nil,
      suppressTokensConfig: SuppressTokensConfig? = nil,
      maxOutputTokens: Int? = nil,
      responseFormat: ResponseFormat? = nil
    ) {
      self.continuation = continuation
      self.conversation = conversation
      self.repetitionPenaltyConfig = repetitionPenaltyConfig
      self.noRepeatNgramConfig = noRepeatNgramConfig
      self.suppressTokensConfig = suppressTokensConfig
      self.maxOutputTokens = maxOutputTokens
      self.responseFormat = responseFormat
    }
  }
}

/// A callback function to bridge the C callback to the Swift AsyncThrowingStream.
// BEGIN SAFE_REPLY_SUPPORT — Foundation-only state shared with the local lifecycle regression.
private enum SafeInferenceFailure: LocalizedError {
  case restartRequired, concurrentSend, manualToolsRequired, malformedChunk, timedOut
  var errorDescription: String? {
    switch self {
    case .restartRequired: return "The local AI runtime needs an app restart before another request."
    case .concurrentSend: return "The local AI runtime is already processing a request."
    case .manualToolsRequired: return "Safe inference requires automaticToolCalling to be false."
    case .malformedChunk: return "The local AI runtime returned an invalid response chunk."
    case .timedOut: return "The local AI runtime did not finish in time. Restart the app before another request."
    }
  }
}

/// One request per independent engine, at most two in this process. Failure is retained for the
/// process lifetime and blocks all new work: an error callback cannot prove that callbacks drained.
private enum SafeInferenceLifetime {
  private static let lock = NSLock()
  private static let defaultEngine = NSObject()
  private static var active: [ObjectIdentifier: AnyObject] = [:]
  private static var quarantined: [AnyObject] = []
  static var requiresRestart: Bool {
    lock.lock(); defer { lock.unlock() }
    return !quarantined.isEmpty
  }
  static func claim(_ owner: AnyObject, engine: AnyObject? = nil) throws {
    lock.lock(); defer { lock.unlock() }
    guard quarantined.isEmpty else { throw SafeInferenceFailure.restartRequired }
    let key = ObjectIdentifier(engine ?? defaultEngine)
    guard active[key] == nil, active.count < 2 else { throw SafeInferenceFailure.concurrentSend }
    active[key] = owner
  }
  static func quarantine(_ owner: AnyObject) {
    lock.lock(); defer { lock.unlock() }
    guard let key = active.first(where: { $0.value === owner })?.key else { return }
    // Both already-active engines can fail. Never replace/release the first failed owner.
    quarantined.append(owner)
    active.removeValue(forKey: key)
  }
  static func releaseSuccessful(_ owner: AnyObject) {
    lock.lock(); defer { lock.unlock() }
    if let key = active.first(where: { $0.value === owner })?.key { active.removeValue(forKey: key) }
  }
}

/// Native content is a delta. Coalesce text without inserting spaces; keep tool-only chunks and
/// channel deltas intact. This accumulator never invokes a tool or treats a chunk as a full reply.
private struct SafeReplyAccumulator {
  private var contents: [[String: Any]] = []
  private var textIndex: Int?
  private var channels: [String: String] = [:]
  private var tools: [[String: Any]] = []
  private(set) var text = ""

  /// Returns false for valid empty deltas, including a role-only message from an empty tool block.
  mutating func append(_ json: String) throws -> Bool {
    guard let data = json.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw SafeInferenceFailure.malformedChunk }
    var recognized = false
    var hasMessage = false
    if let role = object["role"] {
      guard let role = role as? String, ["assistant", "model"].contains(role) else {
        throw SafeInferenceFailure.malformedChunk
      }
    }
    if let value = object["content"] {
      guard let items = value as? [[String: Any]] else { throw SafeInferenceFailure.malformedChunk }
      for item in items {
        guard let kind = item["type"] as? String else { throw SafeInferenceFailure.malformedChunk }
        if kind == "text" {
          guard let delta = item["text"] as? String else { throw SafeInferenceFailure.malformedChunk }
          text += delta
          if let textIndex { contents[textIndex]["text"] = text }
          else { textIndex = contents.count; contents.append(["type": "text", "text": text]) }
        } else {
          guard ["image", "audio", "tool_response"].contains(kind) else { throw SafeInferenceFailure.malformedChunk }
          contents.append(item)
        }
      }
      recognized = true
      hasMessage = hasMessage || !items.isEmpty
    }
    if let value = object["channels"] {
      guard let deltas = value as? [String: String] else { throw SafeInferenceFailure.malformedChunk }
      for (name, delta) in deltas { channels[name, default: ""] += delta }
      recognized = true
      hasMessage = hasMessage || !deltas.isEmpty
    }
    if let value = object["tool_calls"] {
      guard let calls = value as? [[String: Any]] else { throw SafeInferenceFailure.malformedChunk }
      for call in calls {
        guard let function = call["function"] as? [String: Any],
          let name = function["name"] as? String, !name.isEmpty,
          function["arguments"] is [String: Any]
        else { throw SafeInferenceFailure.malformedChunk }
        tools.append(call)
      }
      recognized = true
      hasMessage = hasMessage || !calls.isEmpty
    }
    guard recognized || object.keys.allSatisfy({ $0 == "role" }) else {
      throw SafeInferenceFailure.malformedChunk
    }
    return hasMessage
  }

  func finalJSON() throws -> String {
    var result: [String: Any] = ["role": "assistant"]
    if !contents.isEmpty { result["content"] = contents }
    if !channels.isEmpty { result["channels"] = channels }
    if !tools.isEmpty { result["tool_calls"] = tools }
    // A clean empty completion remains a valid empty answer for the caller's validation/retry.
    if result.count == 1 { result["content"] = [["type": "text", "text": ""]] }
    let data = try JSONSerialization.data(withJSONObject: result)
    guard let json = String(data: data, encoding: .utf8) else { throw SafeInferenceFailure.malformedChunk }
    return json
  }
}
// END SAFE_REPLY_SUPPORT

private final class SafeMessageContext: @unchecked Sendable {
  // Retains Engine through Conversation, including after a failed native request.
  private var conversation: Conversation?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Message, Error>?
  private let onText: (@Sendable (String) -> Void)?
  private var accumulator = SafeReplyAccumulator()
  private var started = false
  private var result: Result<Message, Error>?
  private var delivered = false
  private var watchdog: DispatchSourceTimer?

  deinit { watchdog?.cancel() }

  init(conversation: Conversation, continuation: CheckedContinuation<Message, Error>,
       onText: (@Sendable (String) -> Void)?) {
    self.conversation = conversation
    self.continuation = continuation
    self.onText = onText
  }

  /// The deadline is a fail-closed response bound, never evidence that native work has stopped.
  func startWatchdog(timeoutSeconds: TimeInterval = 120) {
    lock.lock(); defer { lock.unlock() }
    guard watchdog == nil, result == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    timer.schedule(deadline: .now() + timeoutSeconds)
    timer.setEventHandler { [weak self] in self?.timedOut() }
    watchdog = timer
    timer.resume()
  }

  private func timedOut() {
    lock.lock()
    if result == nil { result = .failure(SafeInferenceFailure.timedOut) }
    watchdog?.cancel(); watchdog = nil
    lock.unlock()
    deliverIfReady()
  }

  func startFinished(error: Error?) {
    lock.lock()
    started = true
    if let error { result = .failure(error) }
    if result != nil { watchdog?.cancel(); watchdog = nil }
    lock.unlock()
    deliverIfReady()
  }

  func receive(json: String?, error: String?, isFinal: Bool) {
    var progress: String?
    lock.lock()
    if result == nil {
      do {
        if let error { throw LiteRTLMError.conversation(.invalidResponse(error)) }
        if let json {
          // Empty semantic deltas are valid (e.g. an empty tool block). Message's full-reply
          // parser rejects them, so validate only nonempty deltas; tool-only messages stay intact.
          if try accumulator.append(json) {
            _ = try Conversation.jsonToMessage(json)
            progress = accumulator.text
          }
        }
        if isFinal { result = .success(try Conversation.jsonToMessage(accumulator.finalJSON())) }
      } catch { result = .failure(error) }
    }
    if result != nil { watchdog?.cancel(); watchdog = nil }
    lock.unlock()
    if let progress { onText?(progress) }
    deliverIfReady()
  }

  private func deliverIfReady() {
    lock.lock()
    guard started, !delivered, let result, let continuation else { lock.unlock(); return }
    delivered = true
    self.continuation = nil
    lock.unlock()
    switch result {
    case .failure:
      // Do not cancel, delete, retry, or release on a C error or a Swift parse error. An error may
      // have come from a processing chunk; later callbacks must still find their retained context.
      SafeInferenceLifetime.quarantine(self)
      continuation.resume(with: result)
    case .success:
      // Native Session destruction waits for its tasks. Never run it on the native callback
      // thread, where it could wait for the callback currently executing itself. No delay is used.
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        // Drop this owner's native reference here even if the callback still holds the context.
        // The async method/caller may also own Conversation, but never on the native callback queue.
        conversation = nil
        SafeInferenceLifetime.releaseSuccessful(self)
        continuation.resume(with: result)
      }
    }
  }
}

private func safeMessageCallback(userData: UnsafeMutableRawPointer?, chunk: OpaquePointer?) {
  guard let userData else { return }
  // SafeInferenceLifetime owns this context before C starts and until successful cleanup, or
  // permanently after failure. Never balance ownership on an error callback.
  let context = Unmanaged<SafeMessageContext>.fromOpaque(userData).takeUnretainedValue()
  let json = litert_lm_stream_chunk_get_text(chunk).map { String(cString: $0) }
  let error = litert_lm_stream_chunk_get_error(chunk).map { String(cString: $0) }
  context.receive(json: json, error: error, isFinal: litert_lm_stream_chunk_is_final(chunk))
}

private func streamCallback(
  userData: UnsafeMutableRawPointer?,
  chunk: OpaquePointer?
) {
  guard let userData = userData else { return }

  let context = Unmanaged<Conversation.StreamContext>.fromOpaque(userData).takeUnretainedValue()

  let isFinal = litert_lm_stream_chunk_is_final(chunk)
  let errorMessage = litert_lm_stream_chunk_get_error(chunk)

  if let errorMessage = errorMessage {
    let errorString = String(cString: errorMessage)
    let error = LiteRTLMError.conversation(.invalidResponse(errorString))
    context.continuation.finish(throwing: error)

    Unmanaged<Conversation.StreamContext>.fromOpaque(userData).release()
    return
  }

  if let responseJson = litert_lm_stream_chunk_get_text(chunk) {
    let responseString = String(cString: responseJson)
    do {
      guard let responseData = responseString.data(using: .utf8),
        let jsonObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
      else {
        throw LiteRTLMError.conversation(.invalidJson("Invalid JSON chunk"))
      }

      if let toolCalls = jsonObject["tool_calls"] as? [[String: Any]] {
        context.pendingToolCalls.append(contentsOf: toolCalls)
      }

      if jsonObject["content"] != nil || jsonObject["channels"] != nil {
        let message = try Conversation.jsonToMessage(responseString)
        context.continuation.yield(message)
      }
    } catch {
      logger.error("Failed to parse response JSON: \(error.localizedDescription)")
      context.continuation.finish(throwing: error)
      Unmanaged<Conversation.StreamContext>.fromOpaque(userData).release()
      return
    }
  }

  if isFinal {
    if !context.pendingToolCalls.isEmpty {
      if context.toolCallCount >= recurringToolCallLimit {
        context.continuation.finish(
          throwing: LiteRTLMError.conversation(
            .recurringToolCallLimitExceeded(limit: recurringToolCallLimit)))
        Unmanaged<Conversation.StreamContext>.fromOpaque(userData).release()
        return
      }

      context.toolCallCount += 1
      let toolCalls = context.pendingToolCalls
      context.pendingToolCalls = []

      Task {
        do {
          let toolResponseJson = try await context.conversation.handleToolCalls(toolCalls)
          try context.conversation.sendToStream(
            handle: context.conversation.checkIsAlive(),
            messageJson: toolResponseJson,
            repetitionPenaltyConfig: context.repetitionPenaltyConfig,
            noRepeatNgramConfig: context.noRepeatNgramConfig,
            suppressTokensConfig: context.suppressTokensConfig,
            maxOutputTokens: context.maxOutputTokens,
            responseFormat: context.responseFormat,
            context: context
          )
        } catch {
          context.continuation.finish(throwing: error)
        }
        // Release the reference for the current (finished) call.
        // The new call from sendToStream created its own retained reference.
        Unmanaged<Conversation.StreamContext>.fromOpaque(userData).release()
      }
    } else {
      context.continuation.finish()
      Unmanaged<Conversation.StreamContext>.fromOpaque(userData).release()
    }
  }
}

