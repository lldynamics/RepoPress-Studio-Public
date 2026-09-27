import Foundation
import PublishingCoreSupport

public struct PrivacyProtectionSettings: Codable, Hashable, Sendable {
  public var masksPrivateContent: Bool

  public init(masksPrivateContent: Bool = true) {
    self.masksPrivateContent = masksPrivateContent
  }

  public static var `default`: PrivacyProtectionSettings {
    PrivacyProtectionSettings()
  }

  public var normalized: PrivacyProtectionSettings {
    PrivacyProtectionSettings(masksPrivateContent: masksPrivateContent)
  }

  private enum CodingKeys: String, CodingKey {
    case masksPrivateContent
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      masksPrivateContent: try container.decodeIfPresent(Bool.self, forKey: .masksPrivateContent)
        ?? true
    )
  }
}

public struct PrivateContentDisplay: Codable, Hashable, Sendable {
  public var title: String
  public var summary: String
  public var isMasked: Bool

  public init(title: String, summary: String, isMasked: Bool) {
    self.title = title
    self.summary = summary
    self.isMasked = isMasked
  }
}

/// Retained only to decode privacy events in older workspace snapshots.
public enum PrivacyProtectionEventKind: String, Codable, CaseIterable, Hashable, Sendable {
  case lockedOnLaunch
  case manualLock
  case unlocked
  case settingsUpdated

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    // Snapshots from versions that offered automatic inactivity locking may
    // still contain this transient event. Treat it as a generic manual mask
    // while removing the retired behavior from the current model and UI.
    if value == "lockedWhenInactive" {
      self = .manualLock
    } else if let decoded = Self(rawValue: value) {
      self = decoded
    } else {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Unknown privacy protection event kind: \(value)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var displayName: String {
    switch self {
    case .lockedOnLaunch:
      return CoreL10n.text("启动显示遮罩")
    case .manualLock:
      return CoreL10n.text("手动显示遮罩")
    case .unlocked:
      return CoreL10n.text("已移除遮罩")
    case .settingsUpdated:
      return CoreL10n.text("设置已更新")
    }
  }

  public var systemImage: String {
    switch self {
    case .lockedOnLaunch:
      return "eye.slash"
    case .manualLock:
      return "eye.slash.fill"
    case .unlocked:
      return "eye"
    case .settingsUpdated:
      return "slider.horizontal.3"
    }
  }
}

public struct PrivacyProtectionEvent: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var kind: PrivacyProtectionEventKind
  public var message: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: PrivacyProtectionEventKind,
    message: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.message = message
    self.createdAt = createdAt
  }

  public var checklistLine: String {
    "- \(kind.displayName)：\(message)"
  }
}

public struct PrivacyProtectionStatus: Hashable, Sendable {
  public var title: String
  public var detail: String
  public var activeProtections: [String]

  public init(title: String, detail: String, activeProtections: [String]) {
    self.title = title
    self.detail = detail
    self.activeProtections = activeProtections
  }

  public static func make(settings: PrivacyProtectionSettings) -> PrivacyProtectionStatus {
    PrivacyProtectionStatus(
      title: settings.masksPrivateContent
        ? CoreL10n.text("私密内容遮挡已开启")
        : CoreL10n.text("私密内容遮挡已关闭"),
      detail: settings.masksPrivateContent
        ? CoreL10n.text("私密文章的标题仍显示，列表、搜索和概览中的摘要、正文和路径会被遮挡。此设置不加密本地数据。")
        : CoreL10n.text("私密文章的摘要、正文和路径可在列表、搜索和概览中显示。"),
      activeProtections: settings.masksPrivateContent ? [CoreL10n.text("私密内容遮挡")] : []
    )
  }

  public var checklistMarkdown: String {
    [
      CoreL10n.text("# 私密内容遮挡"),
      "",
      CoreL10n.format("- 当前状态：%@", title),
      CoreL10n.format("- 说明：%@", detail),
      CoreL10n.format(
        "- 已启用的遮挡设置：%@",
        activeProtections.isEmpty ? CoreL10n.text("未启用") : activeProtections.joined(separator: "、")
      ),
      "",
      CoreL10n.text("## 行为确认"),
      CoreL10n.text("- [ ] 私密内容遮挡开启时，标题仍可辨认，但列表、搜索和概览不暴露摘要、正文或路径。"),
      CoreL10n.text("- [ ] 截图、支持页和隐私政策文案不得包含本地路径、Token、授权头或私密正文。"),
    ].joined(separator: "\n")
  }
}
