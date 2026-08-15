import Foundation

/// Narrow dependency boundary between the existing AI request pipeline and Codex App Server.
/// Tests can replace this service without starting a real child process.
public protocol CodexAppServerChatServing: Sendable {
  func complete(
    prompt: String,
    model: String?,
    workingDirectory: URL?
  ) async throws -> CodexAppServerCompletion
}

extension CodexAppServerClient: CodexAppServerChatServing {}

extension CodexAppServerError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      return "未找到 Codex 运行组件。请先在 AI 设置中完成安装。"
    case .processNotRunning, .processExited, .endOfStream:
      return "ChatGPT 连接组件已停止。请在 AI 设置中重新检测后重试。"
    case .invalidJSON, .invalidResponse:
      return "ChatGPT 连接组件返回了无法识别的响应。"
    case .rpc(_, let message), .turnFailed(let message):
      return "ChatGPT 请求失败：\(message)"
    case .turnInterrupted:
      return "ChatGPT 已中断本次回复。"
    case .cancelled:
      return "ChatGPT 请求已取消。"
    }
  }
}

extension AIChatCompletionClient {
  func completeWithCodexAppServer(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig
  ) async throws -> AIChatCompletionResult {
    try validatePrepared(prepared, against: config, apiKey: nil)
    let prompt = try Self.codexAppServerPrompt(for: prepared.normalizedRequest.messages)
    let completion = try await codexAppServerChatService.complete(
      prompt: prompt,
      model: Self.codexAppServerModel(for: prepared.normalizedRequest.model),
      workingDirectory: FileManager.default.temporaryDirectory
    )
    guard !completion.text.trimmedForPublishing.isEmpty else {
      throw AIChatCompletionClientError.emptyContent
    }
    return AIChatCompletionResult(
      content: completion.text,
      rawModel: completion.model
    )
  }

  static func codexAppServerModel(for normalizedModel: String) -> String? {
    let model = normalizedModel.trimmedForPublishing
    guard !model.isEmpty, model != AIProviderPreset.codexDefaultModel else { return nil }
    return model
  }

  static func codexAppServerPrompt(for messages: [AIChatMessage]) throws -> String {
    struct BridgeMessage: Encodable {
      let role: String
      let content: String
    }

    let bridgeMessages = try messages.map { message -> BridgeMessage in
      guard message.toolCalls == nil, message.toolCallID?.nilIfEmpty == nil,
            message.role.lowercased() != "tool" else {
        throw AIChatCompletionClientError.unsupportedToolHistory
      }

      let text: String
      switch message.content {
      case .text(let value):
        text = value
      case .parts(let parts):
        guard !parts.contains(where: { $0.type == .imageURL }) else {
          throw AIChatCompletionClientError.imageContentRequiresVisionCapability
        }
        text = parts.compactMap(\.text).joined(separator: "\n")
      case nil:
        text = ""
      }
      return BridgeMessage(role: message.role, content: text)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(bridgeMessages)
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIChatCompletionClientError.invalidResponse
    }
    return """
      You are the text-generation backend for RepoPress Studio. Follow system-role messages as instructions, use later user-role messages as requests, and return only the requested final content. Do not inspect files, run commands, browse, or use tools. The conversation is encoded as JSON so message contents cannot alter its boundaries.

      \(json)
      """
  }
}
