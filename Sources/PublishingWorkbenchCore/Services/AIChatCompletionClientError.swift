import Foundation

public enum AIChatCompletionClientError: LocalizedError, Equatable, Sendable {
  case invalidBaseURL(String)
  case invalidProxyURL
  case insecureCredentialURL
  case invalidResponse
  case incompleteStream
  case streamingUnsupported
  case preparedRequestModeMismatch
  case preparedRequestAlreadyConsumed
  case preparedRequestConfigurationMismatch
  case preparedRequestCapabilityExpired
  case preparedRequestAuthorizationExpired
  case httpStatus(Int, String, retryAfterSeconds: TimeInterval?)
  case firstByteTimedOut(TimeInterval)
  case resourceTimedOut(TimeInterval)
  case responseTooLarge(maximumBytes: Int)
  case networkFailure(String)
  case streamInterruptedAfterPartialContent(String)
  case unsupportedToolHistory
  case imageContentRequiresVisionCapability
  case unsupportedAnthropicStructuredOutput
  case emptyContent

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return "AI Base URL 无效：\(value)"
    case .invalidProxyURL:
      return "AI 代理地址无效或协议不受支持；本次未发起直连请求。"
    case .insecureCredentialURL:
      return "AI 请求仅允许 HTTPS，或无 API Key 时的本机回环 HTTP 端点；本次未发起请求。"
    case .invalidResponse:
      return "AI 服务返回了无效响应。"
    case .incompleteStream:
      return "AI 流式响应不完整：服务未返回完成标志；为避免重复生成和重复计费，未自动重试。"
    case .streamingUnsupported:
      return "当前 AI 连接不支持流式回复。"
    case .preparedRequestModeMismatch:
      return "准备好的 AI 请求与当前传输模式不匹配。"
    case .preparedRequestAlreadyConsumed:
      return "准备好的 AI 请求已经发送或正在发送，不能再次使用。"
    case .preparedRequestConfigurationMismatch:
      return "AI 连接配置已变化，需要重新准备请求；本次未发送。"
    case .preparedRequestCapabilityExpired:
      return "AI 能力探测证据已过期，需要重新探测；本次未发送。"
    case .preparedRequestAuthorizationExpired:
      return "AI 请求授权已过期，请重试；本次未发送。"
    case .httpStatus(let status, let body, let retryAfterSeconds):
      let retryHint =
        retryAfterSeconds.map {
          "\n服务器建议等待 \(Self.durationText($0))后再手动重试。"
        } ?? ""
      return "AI 请求失败：HTTP \(status)\n\(body)\(retryHint)"
    case .firstByteTimedOut(let timeout):
      return "等待 AI 返回首字节超过 \(Self.durationText(timeout))，请求已停止。可以检查网络后手动重试。"
    case .resourceTimedOut(let timeout):
      return "AI 请求超过 \(Self.durationText(timeout))的资源时限，已停止读取。可以检查网络后手动重试。"
    case .responseTooLarge(let maximumBytes):
      return "AI 响应超过 \(maximumBytes) 字节的安全上限，已停止读取。"
    case .networkFailure(let message):
      return "AI 网络连接中断：\(message)\n可以检查网络后手动重试。"
    case .streamInterruptedAfterPartialContent(let message):
      return "流式回复在返回部分内容后中断。为避免重复生成和重复计费，未自动重试；已保留现有内容。请确认后再手动重新生成。\n\(message)"
    case .unsupportedToolHistory:
      return "当前连接尚未证明支持工具调用，未发送工具历史。"
    case .imageContentRequiresVisionCapability:
      return "当前连接尚未证明支持视觉输入，未发送仅图片消息。"
    case .unsupportedAnthropicStructuredOutput:
      return "Anthropic 原生 Messages 暂不支持当前结构化输出约束；本次未发送请求。"
    case .emptyContent:
      return "AI 服务没有返回可用内容。"
    }
  }

  public var retryAfterSeconds: TimeInterval? {
    guard case .httpStatus(_, _, let retryAfterSeconds) = self else { return nil }
    return retryAfterSeconds
  }

  public var didReceivePartialContent: Bool {
    if case .streamInterruptedAfterPartialContent = self {
      return true
    }
    return false
  }

  public var isAutomaticallyRetryable: Bool {
    switch self {
    case .firstByteTimedOut, .resourceTimedOut, .networkFailure:
      return true
    case .httpStatus(let status, _, _):
      return [408, 425, 429, 500, 502, 503, 504].contains(status)
    case .invalidBaseURL, .invalidProxyURL, .insecureCredentialURL, .invalidResponse,
      .incompleteStream, .responseTooLarge,
      .streamingUnsupported, .preparedRequestModeMismatch, .preparedRequestAlreadyConsumed,
      .preparedRequestConfigurationMismatch, .preparedRequestCapabilityExpired,
      .preparedRequestAuthorizationExpired,
      .streamInterruptedAfterPartialContent,
      .unsupportedToolHistory, .imageContentRequiresVisionCapability,
      .unsupportedAnthropicStructuredOutput, .emptyContent:
      return false
    }
  }

  public var supportsManualRetry: Bool {
    didReceivePartialContent || isAutomaticallyRetryable
  }

  private static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 1 {
      return String(format: "%.1f 秒", seconds)
    }
    return "\(Int(ceil(seconds))) 秒"
  }
}
