import Foundation
import PublishingCoreSupport

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
  case requestContextWindowExceeded(contextWindow: Int)
  case partialTextRecoveryContextTooLarge(maximumBytes: Int)
  case networkFailure(String)
  case streamInterruptedAfterPartialContent(String)
  case unsupportedToolHistory
  case imageContentRequiresVisionCapability
  case unsupportedAnthropicStructuredOutput
  case emptyContent

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      return CoreL10n.format("AI Base URL 无效：%@", value)
    case .invalidProxyURL:
      return CoreL10n.text("AI 代理地址无效或协议不受支持；本次未发起直连请求。")
    case .insecureCredentialURL:
      return CoreL10n.text("AI 请求仅允许 HTTPS，或无 API Key 时的本机回环 HTTP 端点；本次未发起请求。")
    case .invalidResponse:
      return CoreL10n.text("AI 服务返回了无效响应。")
    case .incompleteStream:
      return CoreL10n.text("AI 流式响应不完整：服务未返回完成标志；为避免重复生成和重复计费，未自动重试。")
    case .streamingUnsupported:
      return CoreL10n.text("当前 AI 连接不支持流式回复。")
    case .preparedRequestModeMismatch:
      return CoreL10n.text("准备好的 AI 请求与当前传输模式不匹配。")
    case .preparedRequestAlreadyConsumed:
      return CoreL10n.text("准备好的 AI 请求已经发送或正在发送，不能再次使用。")
    case .preparedRequestConfigurationMismatch:
      return CoreL10n.text("AI 连接配置已变化，需要重新准备请求；本次未发送。")
    case .preparedRequestCapabilityExpired:
      return CoreL10n.text("AI 能力探测证据已过期，需要重新探测；本次未发送。")
    case .preparedRequestAuthorizationExpired:
      return CoreL10n.text("AI 请求授权已过期，请重试；本次未发送。")
    case .httpStatus(let status, let body, let retryAfterSeconds):
      let retryHint =
        retryAfterSeconds.map {
          CoreL10n.format("\n服务器建议等待 %@后再手动重试。", Self.durationText($0))
        } ?? ""
      let recoveryHint = recoverySuggestion.map { CoreL10n.format("\n建议：%@", $0) } ?? ""
      return CoreL10n.format("AI 请求失败：HTTP %d\n%@%@%@", status, body, retryHint, recoveryHint)
    case .firstByteTimedOut(let timeout):
      return CoreL10n.format("等待 AI 返回首字节超过 %@，请求已停止。可以检查网络后手动重试。", Self.durationText(timeout))
    case .resourceTimedOut(let timeout):
      return CoreL10n.format("AI 请求超过 %@的资源时限，已停止读取。可以检查网络后手动重试。", Self.durationText(timeout))
    case .responseTooLarge(let maximumBytes):
      return CoreL10n.format("AI 响应超过 %d 字节的安全上限，已停止读取。", maximumBytes)
    case .requestContextWindowExceeded(let contextWindow):
      return CoreL10n.format(
        "AI 请求无法压缩到模型的 %d Token 上下文窗口内；本次未发送。请缩短必要指令、工具定义或图片输入后重试。",
        contextWindow
      )
    case .partialTextRecoveryContextTooLarge(let maximumBytes):
      return CoreL10n.format("AI 续接上下文超过 %d 字节的安全上限，已停止续接。请缩短上下文后重试。", maximumBytes)
    case .networkFailure(let message):
      return CoreL10n.format("AI 网络连接中断：%@\n可以检查网络后手动重试。", message)
    case .streamInterruptedAfterPartialContent(let message):
      return CoreL10n.format(
        "流式回复在返回部分内容后中断。已保留现有内容；自动续接不可用或未能完成，为避免继续重复生成和重复计费，已停止。请确认后再手动继续。\n%@",
        message
      )
    case .unsupportedToolHistory:
      return CoreL10n.text("当前连接尚未证明支持工具调用，未发送工具历史。")
    case .imageContentRequiresVisionCapability:
      return CoreL10n.text("当前连接尚未证明支持视觉输入，未发送仅图片消息。")
    case .unsupportedAnthropicStructuredOutput:
      return CoreL10n.text("Anthropic 原生 Messages 暂不支持当前结构化输出约束；本次未发送请求。")
    case .emptyContent:
      return CoreL10n.text("AI 服务没有返回可用内容。")
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .httpStatus(let status, let body, _):
      switch status {
      case 401:
        return CoreL10n.text("请检查 API Key 是否正确且仍有效，并确认服务地址与账户所属服务一致。")
      case 403:
        return CoreL10n.text("请检查账户权限、项目权限或地区限制。")
      case 404:
        return CoreL10n.text("请检查模型 ID 与接口路径是否正确。")
      case 429:
        if Self.hasExplicitBalanceError(in: body) {
          return CoreL10n.text("账户余额或配额不足，请到服务商账户页面检查余额和用量。")
        }
        return CoreL10n.text("请求过于频繁，请稍后重试或减少并发。")
      case 500...599:
        return CoreL10n.text("服务暂时异常，请稍后重试并查看服务状态。")
      default:
        return nil
      }
    case .firstByteTimedOut, .resourceTimedOut:
      return CoreL10n.text("请求超时，请检查网络或稍后手动重试。")
    case .networkFailure:
      return CoreL10n.text("请检查网络连接、代理和服务地址后手动重试。")
    default:
      return nil
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
      .incompleteStream, .responseTooLarge, .requestContextWindowExceeded,
      .partialTextRecoveryContextTooLarge,
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
      return CoreL10n.format("%.1f 秒", seconds)
    }
    return CoreL10n.format("%d 秒", Int(ceil(seconds)))
  }

  private static func hasExplicitBalanceError(in body: String) -> Bool {
    guard let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any],
      let error = root["error"] as? [String: Any]
    else {
      return false
    }
    let values = [error["code"], error["type"]].compactMap { $0 as? String }
    let balanceCodes: Set<String> = [
      "insufficient_quota", "quota_exceeded", "insufficient_balance",
    ]
    return values.contains { balanceCodes.contains($0.lowercased()) }
  }
}
