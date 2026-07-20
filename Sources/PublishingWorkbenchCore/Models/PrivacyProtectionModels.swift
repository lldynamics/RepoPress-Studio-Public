import Foundation

public struct PrivacyProtectionSettings: Codable, Hashable, Sendable {
  public static let defaultInactivityLockDelayMinutes = 10
  public static let minimumInactivityLockDelayMinutes = 1
  public static let maximumInactivityLockDelayMinutes = 240

  public var masksPrivateContent: Bool
  public var locksWhenInactive: Bool
  public var inactivityLockDelayMinutes: Int

  public init(
    masksPrivateContent: Bool = true,
    locksWhenInactive: Bool = false,
    inactivityLockDelayMinutes: Int = Self.defaultInactivityLockDelayMinutes
  ) {
    self.masksPrivateContent = masksPrivateContent
    self.locksWhenInactive = locksWhenInactive
    self.inactivityLockDelayMinutes = Self.clampedInactivityLockDelayMinutes(
      inactivityLockDelayMinutes
    )
  }

  public static var `default`: PrivacyProtectionSettings {
    PrivacyProtectionSettings()
  }

  public var effectiveInactivityLockDelayMinutes: Int {
    Self.clampedInactivityLockDelayMinutes(inactivityLockDelayMinutes)
  }

  public var inactivityLockInterval: TimeInterval? {
    guard locksWhenInactive else { return nil }
    return TimeInterval(effectiveInactivityLockDelayMinutes * 60)
  }

  public var normalized: PrivacyProtectionSettings {
    PrivacyProtectionSettings(
      masksPrivateContent: masksPrivateContent,
      locksWhenInactive: locksWhenInactive,
      inactivityLockDelayMinutes: inactivityLockDelayMinutes
    )
  }

  private enum CodingKeys: String, CodingKey {
    case masksPrivateContent
    case locksWhenInactive
    case inactivityLockDelayMinutes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      masksPrivateContent: try container.decodeIfPresent(Bool.self, forKey: .masksPrivateContent) ?? true,
      locksWhenInactive: try container.decodeIfPresent(Bool.self, forKey: .locksWhenInactive) ?? false,
      inactivityLockDelayMinutes: try container.decodeIfPresent(
        Int.self,
        forKey: .inactivityLockDelayMinutes
      ) ?? Self.defaultInactivityLockDelayMinutes
    )
  }

  private static func clampedInactivityLockDelayMinutes(_ value: Int) -> Int {
    min(max(value, minimumInactivityLockDelayMinutes), maximumInactivityLockDelayMinutes)
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
  case lockedWhenInactive
  case manualLock
  case unlocked
  case settingsUpdated

  public var displayName: String {
    switch self {
    case .lockedOnLaunch:
      return "启动显示遮罩"
    case .lockedWhenInactive:
      return "后台自动显示遮罩"
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
      return "lock.shield"
    case .lockedWhenInactive:
      return "rectangle.on.rectangle.slash"
    case .manualLock:
      return "lock.fill"
    case .unlocked:
      return "lock.open"
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
  public var isLocked: Bool
  public var title: String
  public var detail: String
  public var activeProtections: [String]

  public init(
    isLocked: Bool,
    title: String,
    detail: String,
    activeProtections: [String]
  ) {
    self.isLocked = isLocked
    self.title = title
    self.detail = detail
    self.activeProtections = activeProtections
  }

  public static func make(
    settings: PrivacyProtectionSettings,
    isLocked: Bool,
    reason: String?
  ) -> PrivacyProtectionStatus {
    var protections: [String] = []
    if settings.masksPrivateContent {
      protections.append("私密内容遮挡")
    }
    if settings.locksWhenInactive {
      protections.append("无操作 \(settings.effectiveInactivityLockDelayMinutes) 分钟自动锁定")
    }

    return PrivacyProtectionStatus(
      isLocked: isLocked,
      title: isLocked ? "工作台内容已隐藏" : "工作台内容可见",
      detail: isLocked
        ? (reason?.nilIfEmpty ?? "返回工作台后可继续查看文章、仓库和发布信息。")
        : unlockedDetail(settings: settings),
      activeProtections: protections
    )
  }

  private static func unlockedDetail(settings: PrivacyProtectionSettings) -> String {
    if settings.locksWhenInactive {
      return "连续 \(settings.effectiveInactivityLockDelayMinutes) 分钟未操作会自动锁定；也可按 ⌃⌘L 立即锁定。"
    }
    return "当前可查看工作台内容；离席或共享屏幕时可按 ⌃⌘L 立即锁定。"
  }

  public var checklistMarkdown: String {
    var lines: [String] = [
      "# 快速隐藏和私密内容保护",
      "",
      "- 当前状态：\(title)",
      "- 说明：\(detail)",
      "- 启用保护：\(activeProtections.isEmpty ? "未启用" : activeProtections.joined(separator: "、"))",
      "",
      "## 行为确认"
    ]

    lines.append("- [ ] 手动快速隐藏后，主窗口和设置窗口都遮挡工作台内容。")
    if activeProtections.contains(where: { $0.contains("自动锁定") }) {
      lines.append("- [ ] 达到用户设置的无操作时间后，主窗口和设置窗口自动锁定。")
    }
    lines.append("- [ ] 工作台隐藏时，设置项以及写作、AI、同步和发布操作不可用。")
    lines.append("- [ ] 私密内容遮挡开启时，标题仍可辨认，但列表、搜索和概览不暴露摘要、正文或路径。")
    lines.append("- [ ] 截图、支持页和隐私政策文案不得包含本地路径、Token、授权头或私密正文。")

    return lines.joined(separator: "\n")
  }
}
