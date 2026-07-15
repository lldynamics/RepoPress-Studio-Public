import Foundation

public struct PrivacyProtectionSettings: Codable, Hashable, Sendable {
  public var masksPrivateContent: Bool

  public init(
    masksPrivateContent: Bool = true
  ) {
    self.masksPrivateContent = masksPrivateContent
  }

  public static var `default`: PrivacyProtectionSettings {
    PrivacyProtectionSettings()
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

    return PrivacyProtectionStatus(
      isLocked: isLocked,
      title: isLocked ? "工作台内容已隐藏" : "工作台内容可见",
      detail: isLocked
        ? (reason?.nilIfEmpty ?? "返回工作台后可继续查看文章、仓库和发布信息。")
        : "当前可查看工作台内容；需要离席或共享屏幕时可手动快速隐藏。",
      activeProtections: protections
    )
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
    lines.append("- [ ] 工作台隐藏时，设置项以及写作、AI、同步和发布操作不可用。")
    lines.append("- [ ] 私密内容遮挡开启时，列表、搜索和概览不暴露私密文章标题、摘要或路径。")
    lines.append("- [ ] 截图、支持页和隐私政策文案不得包含本地路径、Token、授权头或私密正文。")

    return lines.joined(separator: "\n")
  }
}

public enum PrivacyProtectionRiskLevel: String, CaseIterable, Hashable, Sendable {
  case protected
  case watch
  case exposed

  public var displayName: String {
    switch self {
    case .protected:
      return "已保护"
    case .watch:
      return "需关注"
    case .exposed:
      return "有暴露风险"
    }
  }

  public var systemImage: String {
    switch self {
    case .protected:
      return "checkmark.shield"
    case .watch:
      return "eye"
    case .exposed:
      return "exclamationmark.triangle"
    }
  }
}

public struct PrivacyProtectionAudit: Hashable, Sendable {
  public var level: PrivacyProtectionRiskLevel
  public var title: String
  public var message: String
  public var privateDraftCount: Int
  public var maskedPrivateDraftCount: Int
  public var visiblePrivateDraftCount: Int
  public var activeProtections: [String]
  public var recommendations: [String]

  public init(
    level: PrivacyProtectionRiskLevel,
    title: String,
    message: String,
    privateDraftCount: Int,
    maskedPrivateDraftCount: Int,
    visiblePrivateDraftCount: Int,
    activeProtections: [String],
    recommendations: [String]
  ) {
    self.level = level
    self.title = title
    self.message = message
    self.privateDraftCount = privateDraftCount
    self.maskedPrivateDraftCount = maskedPrivateDraftCount
    self.visiblePrivateDraftCount = visiblePrivateDraftCount
    self.activeProtections = activeProtections
    self.recommendations = recommendations
  }

  public static func make(
    settings: PrivacyProtectionSettings,
    status: PrivacyProtectionStatus,
    privateDraftCount: Int
  ) -> PrivacyProtectionAudit {
    let maskedCount = settings.masksPrivateContent ? privateDraftCount : 0
    let visibleCount = settings.masksPrivateContent ? 0 : privateDraftCount
    var recommendations: [String] = []

    if !settings.masksPrivateContent && privateDraftCount > 0 {
      recommendations.append("开启私密内容遮挡，列表、搜索和概览不显示私密标题或路径。")
    }
    if !status.isLocked {
      recommendations.append("离席或共享屏幕前可手动快速隐藏工作台。")
    }

    let level: PrivacyProtectionRiskLevel
    if visibleCount > 0 {
      level = .exposed
    } else if !settings.masksPrivateContent {
      level = .watch
    } else {
      level = .protected
    }

    let title: String
    let message: String
    switch level {
    case .protected:
      title = "隐私保护已覆盖"
      message = privateDraftCount > 0
        ? "\(maskedCount) 篇私密文章已在列表、搜索和概览中遮挡。"
        : "当前 Profile 没有私密文章，内容遮挡策略已就绪。"
    case .watch:
      title = "隐私保护需要关注"
      message = "当前没有私密文章，但私密内容遮挡尚未开启。"
    case .exposed:
      title = "私密内容有暴露风险"
      message = visibleCount > 0
        ? "\(visibleCount) 篇私密文章可能在列表、搜索或概览中显示。"
        : "私密内容遮挡未开启，私密文章可能在工作台中显示。"
    }

    return PrivacyProtectionAudit(
      level: level,
      title: title,
      message: message,
      privateDraftCount: privateDraftCount,
      maskedPrivateDraftCount: maskedCount,
      visiblePrivateDraftCount: visibleCount,
      activeProtections: status.activeProtections,
      recommendations: recommendations
    )
  }

  public var checklistMarkdown: String {
    var lines = [
      "# 隐私保护体检",
      "",
      "- 状态：\(level.displayName)",
      "- 结论：\(title)",
      "- 说明：\(message)",
      "- 私密文章：\(privateDraftCount)",
      "- 已遮挡：\(maskedPrivateDraftCount)",
      "- 可见风险：\(visiblePrivateDraftCount)",
      "- 启用保护：\(activeProtections.isEmpty ? "未启用" : activeProtections.joined(separator: "、"))",
    ]

    lines.append("")
    lines.append("## 建议")
    if recommendations.isEmpty {
      lines.append("- 当前没有必须处理的隐私保护建议。")
    } else {
      lines.append(contentsOf: recommendations.map { "- [ ] \($0)" })
    }
    return lines.joined(separator: "\n")
  }
}

public struct PrivacyProtectionEvidencePackage: Hashable, Sendable {
  public var status: PrivacyProtectionStatus
  public var audit: PrivacyProtectionAudit
  public var recentEvents: [PrivacyProtectionEvent]

  public init(
    status: PrivacyProtectionStatus,
    audit: PrivacyProtectionAudit,
    recentEvents: [PrivacyProtectionEvent]
  ) {
    self.status = status
    self.audit = audit
    self.recentEvents = recentEvents
  }

  public var checklistMarkdown: String {
    var lines: [String] = [
      "# 隐私保护证据包",
      "",
      "## 当前状态",
      "- 状态：\(status.title)",
      "- 说明：\(status.detail)",
      "- 启用保护：\(status.activeProtections.isEmpty ? "未启用" : status.activeProtections.joined(separator: "、"))",
      "",
      "## 隐私体检",
      "- 风险等级：\(audit.level.displayName)",
      "- 结论：\(audit.title)",
      "- 说明：\(audit.message)",
      "- 私密文章：\(audit.privateDraftCount)",
      "- 已遮挡：\(audit.maskedPrivateDraftCount)",
      "- 可见风险：\(audit.visiblePrivateDraftCount)",
      "",
      "## 最近隐私事件"
    ]

    if recentEvents.isEmpty {
      lines.append("- 暂无隐私保护事件记录。")
    } else {
      lines.append(contentsOf: recentEvents.prefix(8).map(\.checklistLine))
    }

    lines.append("")
    lines.append("## 建议验证")
    lines.append("- [ ] 手动快速隐藏后，AI、同步、发布和设置里的敏感操作不可用。")
    lines.append("- [ ] 私密内容遮挡开启时，列表、搜索、概览、AI 上下文和复制包不暴露私密标题、路径或正文。")
    lines.append("")
    lines.append("## 本地检查命令")
    lines.append("- `swift test --filter PrivacyProtectionTests`")
    lines.append("- `bash script/check_privacy_support_copy.sh`")
    lines.append("- `bash script/check_screenshot_privacy.sh`")

    return lines.joined(separator: "\n")
  }
}
