import Foundation

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
      masksPrivateContent: try container.decodeIfPresent(Bool.self, forKey: .masksPrivateContent) ?? true
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
      return "启动显示遮罩"
    case .manualLock:
      return "手动显示遮罩"
    case .unlocked:
      return "已移除遮罩"
    case .settingsUpdated:
      return "设置已更新"
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
  public var isQuickHideActive: Bool
  public var title: String
  public var detail: String
  public var activeProtections: [String]

  public init(
    isQuickHideActive: Bool,
    title: String,
    detail: String,
    activeProtections: [String]
  ) {
    self.isQuickHideActive = isQuickHideActive
    self.title = title
    self.detail = detail
    self.activeProtections = activeProtections
  }

  public static func make(
    settings: PrivacyProtectionSettings,
    isQuickHideActive: Bool,
    reason: String?
  ) -> PrivacyProtectionStatus {
    var protections: [String] = []
    if settings.masksPrivateContent {
      protections.append("私密内容遮挡")
    }

    return PrivacyProtectionStatus(
      isQuickHideActive: isQuickHideActive,
      title: isQuickHideActive ? "快速隐藏已启用" : "快速隐藏未启用",
      detail: isQuickHideActive
        ? quickHideDetail(reason: reason)
        : unlockedDetail,
      activeProtections: protections
    )
  }

  private static func quickHideDetail(reason: String?) -> String {
    let reasonText = reason?.nilIfEmpty ?? "返回工作台后可继续查看文章、仓库和发布信息。"
    return "\(reasonText) 快速隐藏仅遮挡当前界面，不加密本地数据。"
  }

  private static var unlockedDetail: String {
    return "当前可查看工作台内容；离席或共享屏幕时可按 ⌃⌘L 快速隐藏。快速隐藏仅遮挡当前界面，不加密本地数据。"
  }

  public var checklistMarkdown: String {
    var lines: [String] = [
      "# 快速隐藏和私密内容遮挡",
      "",
      "- 当前状态：\(title)",
      "- 说明：\(detail)",
      "- 已启用的遮挡设置：\(activeProtections.isEmpty ? "未启用" : activeProtections.joined(separator: "、"))",
      "",
      "## 行为确认"
    ]

    lines.append("- [ ] 手动快速隐藏后，主窗口和设置窗口都遮挡工作台内容。")
    lines.append("- [ ] 工作台隐藏时，设置项以及写作、AI、同步和发布操作不可用。")
    lines.append("- [ ] 私密内容遮挡开启时，标题仍可辨认，但列表、搜索和概览不暴露摘要、正文或路径。")
    lines.append("- [ ] 快速隐藏只遮挡当前界面，不提供 Touch ID/密码验证或数据加密。")
    lines.append("- [ ] 截图、支持页和隐私政策文案不得包含本地路径、Token、授权头或私密正文。")

    return lines.joined(separator: "\n")
  }
}
