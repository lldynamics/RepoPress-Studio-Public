import Foundation
import PublishingCoreSupport
import Security

public enum KeychainTokenStoreError: LocalizedError, Equatable {
  case invalidData
  case invalidCredentialOrigin(String)
  case unhandledStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidData:
      return CoreL10n.text("Keychain 返回了不可解析的 token 数据。")
    case .invalidCredentialOrigin(let value):
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return CoreL10n.text("API Base URL 尚未配置。")
      }
      return CoreL10n.format("凭据端点必须是有效的 HTTPS 地址：%@", value)
    case .unhandledStatus(let status):
      return CoreL10n.format(
        "无法访问系统钥匙串（错误码 %@）：%@",
        String(status),
        Self.statusDescription(for: status),
      )
    }
  }

  public var recoveryHint: String? {
    switch self {
    case .invalidData:
      return CoreL10n.text("请检查该服务在钥匙串中的记录是否损坏，可删除后重新保存 Token。")
    case .invalidCredentialOrigin:
      return CoreL10n.text("请先修正 API Base URL；端点变化后需要重新保存对应 Token。")
    case .unhandledStatus(let status):
      switch status {
      case errSecInteractionNotAllowed:
        return CoreL10n.text("系统当前禁止了本应用的钥匙串访问。请前往“系统设置” → “隐私与安全性” → “钥匙串”，允许本应用访问该服务后重试。")
      case errSecAuthFailed:
        return CoreL10n.text("钥匙串认证失败。可尝试重启电脑或重新登录系统后重试。")
      case errSecNoSuchKeychain:
        return CoreL10n.text("应用未连接到登录钥匙串。请使用项目的统一启动脚本重新启动；若仍失败，请在“钥匙串访问”中确认 login 钥匙串可用。")
      case errSecInvalidOwnerEdit, -25253:
        return CoreL10n.text(
          "当前本地构建无法继续使用旧构建创建的钥匙串访问上下文。请重启最新构建后重新保存；如果仍失败，可在“钥匙串访问”中删除对应的 PersonalSitePublisher 旧项后再保存。"
        )
      case errSecItemNotFound:
        return CoreL10n.text("对应 Profile 的钥匙串条目不存在，请先点击“保存”写入 Token。")
      case errSecUserCanceled:
        return CoreL10n.text("你已取消了系统授权提示，请重新触发操作并在授权弹窗中选择允许。")
      default:
        return nil
      }
    }
  }

  public var recoverySuggestion: String? {
    recoveryHint
  }

  private static func statusDescription(for status: OSStatus) -> String {
    if status == errSecParam {
      return CoreL10n.text("系统无法处理这次钥匙串请求。请重试；如果仍失败，请重新启动应用。")
    }
    if let message = SecCopyErrorMessageString(status, nil) {
      return "\(message)"
    }
    return CoreL10n.text("未知错误")
  }

}
