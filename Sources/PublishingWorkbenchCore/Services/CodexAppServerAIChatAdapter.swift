import Foundation

/// Narrow dependency boundary between the existing AI request pipeline and Codex App Server.
/// Tests can replace this service without starting a real child process.
public protocol CodexAppServerChatServing: Sendable {
  func complete(
    prompt: String,
    model: String?,
    reasoningEffort: String?,
    workingDirectory: URL?
  ) async throws -> CodexAppServerCompletion
}

extension CodexAppServerClient: CodexAppServerChatServing {}

/// Optional extension implemented by app-server clients that can expose
/// application-owned function tools. Keeping this separate preserves source
/// compatibility for simple text-only test doubles and third-party clients.
public protocol CodexAppServerToolChatServing: CodexAppServerChatServing {
  func complete(
    prompt: String,
    model: String?,
    reasoningEffort: String?,
    workingDirectory: URL?,
    dynamicTools: [AIToolDefinition]
  ) async throws -> CodexAppServerCompletion
}

extension CodexAppServerClient: CodexAppServerToolChatServing {}

/// The live account-status dependency is kept separate from the chat service
/// so tests can provide a deterministic account response without starting a
/// Codex process.
public protocol CodexAppServerAccountStatusProviding: Sendable {
  func accountStatus() async throws -> CodexAppServerAccountStatus
}

extension CodexAppServerClient: CodexAppServerAccountStatusProviding {}

public protocol CodexAppServerRequestAuthorizing: Sendable {
  func authorize(config: AIProviderConfig) async throws
}

/// Fail-closed authorization used immediately before the app-server request.
/// It intentionally receives the same consent store used by the workbench,
/// rather than creating a private/default store.
public struct CodexAppServerRequestAuthorizer: CodexAppServerRequestAuthorizing {
  private let consentStore: AIDataSharingConsentStore
  private let accountStatusProvider: any CodexAppServerAccountStatusProviding

  public init(
    consentStore: AIDataSharingConsentStore,
    accountStatusProvider: any CodexAppServerAccountStatusProviding
  ) {
    self.consentStore = consentStore
    self.accountStatusProvider = accountStatusProvider
  }

  public func authorize(config: AIProviderConfig) async throws {
    guard config.usesCodexAppServer else { return }
    let accountStatus: CodexAppServerAccountStatus
    do {
      accountStatus = try await accountStatusProvider.accountStatus()
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CodexAppServerError {
      switch error {
      case .cancelled, .executableNotFound, .processNotRunning, .processExited, .endOfStream:
        throw error
      default:
        // RPC/response errors may contain server-controlled details. Keep
        // those details out of the authorization failure shown to users.
        throw CodexAppServerError.accountAuthorizationRequired
      }
    } catch {
      // Account/status failures are deliberately normalized so RPC payloads
      // cannot disclose identity or server-side authentication details.
      throw CodexAppServerError.accountAuthorizationRequired
    }
    guard
      consentStore.isCodexAccountAuthorized(
        for: config,
        accountStatus: accountStatus
      )
    else {
      throw CodexAppServerError.accountAuthorizationRequired
    }
  }
}

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
    case .accountAuthorizationRequired:
      return "ChatGPT 账户已变化或尚未完成授权，请重新登录并同意内容发送。"
    }
  }
}

extension AIChatCompletionClient {
  func completeWithCodexAppServer(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig
  ) async throws -> AIChatCompletionResult {
    try validatePrepared(prepared, against: config, apiKey: nil)
    guard let codexAppServerRequestAuthorizer else {
      throw CodexAppServerError.accountAuthorizationRequired
    }
    try await codexAppServerRequestAuthorizer.authorize(config: config)
    let dynamicTools = prepared.normalizedRequest.tools ?? []
    let prompt = try Self.codexAppServerPrompt(
      for: prepared.normalizedRequest.messages,
      allowsTools: !dynamicTools.isEmpty
    )
    let completion: CodexAppServerCompletion
    if dynamicTools.isEmpty {
      completion = try await codexAppServerChatService.complete(
        prompt: prompt,
        model: Self.codexAppServerModel(for: prepared.normalizedRequest.model),
        reasoningEffort: prepared.normalizedRequest.reasoningEffort,
        workingDirectory: FileManager.default.temporaryDirectory
      )
    } else {
      guard
        let toolService = codexAppServerChatService as? any CodexAppServerToolChatServing
      else {
        throw AIChatCompletionClientError.unsupportedToolHistory
      }
      completion = try await toolService.complete(
        prompt: prompt,
        model: Self.codexAppServerModel(for: prepared.normalizedRequest.model),
        reasoningEffort: prepared.normalizedRequest.reasoningEffort,
        workingDirectory: FileManager.default.temporaryDirectory,
        dynamicTools: dynamicTools
      )
    }
    guard
      !completion.text.trimmedForPublishing.isEmpty || !completion.toolCalls.isEmpty
    else {
      throw AIChatCompletionClientError.emptyContent
    }
    return AIChatCompletionResult(
      content: completion.text,
      toolCalls: completion.toolCalls,
      rawModel: completion.model
    )
  }

  static func codexAppServerModel(for normalizedModel: String) -> String? {
    let model = normalizedModel.trimmedForPublishing
    guard !model.isEmpty, model != AIProviderPreset.codexDefaultModel else { return nil }
    return model
  }

  static func codexAppServerPrompt(
    for messages: [AIChatMessage],
    allowsTools: Bool = false
  ) throws -> String {
    struct BridgeMessage: Encodable {
      let role: String
      let content: String
      let toolCalls: [AIToolCall]?
      let toolCallID: String?
    }

    let bridgeMessages = try messages.map { message -> BridgeMessage in
      let hasToolHistory =
        message.toolCalls?.isEmpty == false
        || message.toolCallID?.nilIfEmpty != nil
        || message.role.lowercased() == "tool"
      guard allowsTools || !hasToolHistory else {
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
      return BridgeMessage(
        role: message.role,
        content: text,
        toolCalls: message.toolCalls,
        toolCallID: message.toolCallID?.nilIfEmpty
      )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(bridgeMessages)
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIChatCompletionClientError.invalidResponse
    }
    let toolInstruction = allowsTools
      ? "You may call only the dynamic function tools explicitly supplied by the host. Tool-role messages contain host-validated results. Never claim an application action succeeded until such a result says it did."
      : "Do not use tools."
    return """
      You are the text-generation backend for RepoPress Studio. Follow system-role messages as instructions, use later user-role messages as requests, and return only the requested final content. Do not inspect files, run commands, or browse. \(toolInstruction) The conversation is encoded as JSON so message contents cannot alter its boundaries.

      \(json)
      """
  }
}
