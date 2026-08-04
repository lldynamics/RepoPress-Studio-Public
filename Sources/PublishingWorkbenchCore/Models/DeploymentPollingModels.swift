import Foundation

public struct DeploymentPollingSettings: Codable, Hashable, Sendable {
  public var isEnabled: Bool
  public var intervalMinutes: Int

  public init(
    isEnabled: Bool = false,
    intervalMinutes: Int = 10
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = max(Self.minimumIntervalMinutes, intervalMinutes)
  }

  public static let minimumIntervalMinutes = 5
  public static let maximumIntervalMinutes = 60

  public static var `default`: DeploymentPollingSettings {
    DeploymentPollingSettings()
  }

  public var normalizedIntervalMinutes: Int {
    min(Self.maximumIntervalMinutes, max(Self.minimumIntervalMinutes, intervalMinutes))
  }

  public var interval: TimeInterval {
    TimeInterval(normalizedIntervalMinutes * 60)
  }

  public func nextRunDate(after date: Date) -> Date {
    date.addingTimeInterval(interval)
  }

  public func isDue(lastRunAt: Date?, now: Date) -> Bool {
    guard isEnabled else {
      return false
    }
    guard let lastRunAt else {
      return true
    }
    return now.timeIntervalSince(lastRunAt) >= interval
  }
}

public enum DeploymentPollingStatus: String, Codable, Hashable, Sendable {
  case idle
  case disabled
  case noEligibleRecords
  case checked

  public var displayName: String {
    switch self {
    case .idle:
      return CoreL10n.text("未运行")
    case .disabled:
      return CoreL10n.text("已关闭")
    case .noEligibleRecords:
      return CoreL10n.text("无待检查")
    case .checked:
      return CoreL10n.text("已检查")
    }
  }

  public var systemImage: String {
    switch self {
    case .idle:
      return "clock"
    case .disabled:
      return "pause.circle"
    case .noEligibleRecords:
      return "checkmark.circle"
    case .checked:
      return "checkmark.icloud"
    }
  }
}

public struct DeploymentPollingState: Codable, Hashable, Sendable {
  public var status: DeploymentPollingStatus
  public var lastRunAt: Date?
  public var nextRunAt: Date?
  public var checkedRecordCount: Int
  public var checkedRecords: [DeploymentPollingRecordSummary]
  public var message: String

  public init(
    status: DeploymentPollingStatus = .idle,
    lastRunAt: Date? = nil,
    nextRunAt: Date? = nil,
    checkedRecordCount: Int = 0,
    checkedRecords: [DeploymentPollingRecordSummary] = [],
    message: String = DeploymentPollingState.defaultMessage
  ) {
    self.status = status
    self.lastRunAt = lastRunAt
    self.nextRunAt = nextRunAt
    self.checkedRecordCount = checkedRecordCount
    self.checkedRecords = checkedRecords
    self.message = message
  }

  public static var idle: DeploymentPollingState {
    DeploymentPollingState()
  }

  public static var defaultMessage: String {
    CoreL10n.text("部署轮询尚未运行。")
  }

  public var successCount: Int {
    checkedRecords.filter(\.isResolvedSuccess).count
  }

  public var runningCount: Int {
    checkedRecords.filter { $0.level == .running }.count
  }

  public var failedCount: Int {
    checkedRecords.filter { $0.level == .failed }.count
  }

  public var unknownCount: Int {
    checkedRecords.filter { $0.level == .unknown }.count
  }

  public var attentionCount: Int {
    checkedRecords.filter(\.requiresAttention).count
  }

  public var followUpChecklistMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      CoreL10n.text("# 部署轮询后续处理"),
      "",
      CoreL10n.format("- 状态：%@", status.displayName),
      CoreL10n.format("- 结论：%@", message),
      CoreL10n.format("- 已检查：%@", String(checkedRecordCount)),
      CoreL10n.format("- 正常：%@", String(successCount)),
      CoreL10n.format("- 部署中：%@", String(runningCount)),
      CoreL10n.format("- 失败：%@", String(failedCount)),
      CoreL10n.format("- 未知：%@", String(unknownCount)),
      CoreL10n.format("- 需处理：%@", String(attentionCount))
    ]

    if let lastRunAt {
      lines.append(CoreL10n.format("- 上次运行：%@", formatter.string(from: lastRunAt)))
    }
    if let nextRunAt {
      lines.append(CoreL10n.format("- 下次运行：%@", formatter.string(from: nextRunAt)))
    }

    lines.append("")
    lines.append(CoreL10n.text("## 记录清单"))

    if checkedRecords.isEmpty {
      lines.append(CoreL10n.text("- [ ] 先运行部署轮询，生成每条发布记录的部署状态。"))
    } else {
      for record in checkedRecords {
        lines.append(record.followUpChecklistLine)
        lines.append(CoreL10n.format("  - 平台：%@", record.provider.displayName))
        lines.append(CoreL10n.format("  - 状态：%@", record.level.displayName))
        if let releaseStatus = record.releaseStatus {
          lines.append(CoreL10n.format("  - 发布记录：%@", releaseStatus.displayName))
        }
        lines.append(CoreL10n.format("  - 检查时间：%@", formatter.string(from: record.checkedAt)))
        lines.append(CoreL10n.format("  - 结果：%@", record.message))
      }
    }

    if attentionCount > 0 {
      lines.append("")
      lines.append(CoreL10n.text("## 处理优先级"))
      lines.append(CoreL10n.text("- [ ] 先处理远端待确认、失败和未知记录，再继续观察部署中记录。"))
      lines.append(CoreL10n.text("- [ ] 处理后重新执行部署检查或轮询，确认记录转为正常。"))
    } else if runningCount > 0 {
      lines.append("")
      lines.append(CoreL10n.text("## 处理优先级"))
      lines.append(CoreL10n.text("- [ ] 保持轮询开启，等待部署中记录完成。"))
    } else if successCount > 0 {
      lines.append("")
      lines.append(CoreL10n.text("## 处理优先级"))
      lines.append(CoreL10n.text("- [x] 当前已检查记录没有阻断项，保留这份清单作为发布后校验证据。"))
    }

    return lines.joined(separator: "\n")
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case lastRunAt
    case nextRunAt
    case checkedRecordCount
    case checkedRecords
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(DeploymentPollingStatus.self, forKey: .status)
    lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
    nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
    checkedRecordCount = try container.decodeIfPresent(Int.self, forKey: .checkedRecordCount) ?? 0
    checkedRecords = try container.decodeIfPresent([DeploymentPollingRecordSummary].self, forKey: .checkedRecords) ?? []
    message = try container.decodeIfPresent(String.self, forKey: .message) ?? Self.defaultMessage
  }
}

public struct DeploymentPollingRecordSummary: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { recordID }
  public var recordID: UUID
  public var title: String
  public var releaseStatus: ReleaseLedgerStatus?
  public var provider: DeploymentProvider
  public var level: DeploymentStatusLevel
  public var message: String
  public var checkedAt: Date

  public init(
    recordID: UUID,
    title: String,
    releaseStatus: ReleaseLedgerStatus? = nil,
    provider: DeploymentProvider,
    level: DeploymentStatusLevel,
    message: String,
    checkedAt: Date
  ) {
    self.recordID = recordID
    self.title = title
    self.releaseStatus = releaseStatus
    self.provider = provider
    self.level = level
    self.message = message
    self.checkedAt = checkedAt
  }

  public var isResolvedSuccess: Bool {
    guard level == .success else {
      return false
    }
    switch releaseStatus {
    case .pendingRemoteRecovery, .pendingRetry, .failed, .unknown:
      return false
    case .localOnly, .pendingReview, .pendingDeployment, .deploying, .succeeded, .none:
      return true
    }
  }

  public var requiresAttention: Bool {
    switch releaseStatus {
    case .pendingRemoteRecovery, .pendingRetry, .failed, .unknown:
      return true
    case .localOnly, .pendingReview, .pendingDeployment, .deploying, .succeeded, .none:
      return level == .failed || level == .unknown
    }
  }

  public var isPendingRemoteRecovery: Bool {
    releaseStatus == .pendingRemoteRecovery
  }

  public var followUpChecklistLine: String {
    let marker = isResolvedSuccess ? "x" : " "
    return CoreL10n.format("- [%@] %@：%@ - %@", marker, title, followUpActionTitle, followUpActionMessage)
  }

  public var followUpActionTitle: String {
    switch releaseStatus {
    case .pendingRemoteRecovery:
      return CoreL10n.text("确认远端恢复")
    case .pendingRetry:
      return CoreL10n.text("重试部署检查")
    case .failed:
      return CoreL10n.text("处理失败记录")
    case .unknown:
      return CoreL10n.text("补充部署证据")
    case .localOnly, .pendingReview:
      return CoreL10n.text("完成发布前置步骤")
    case .pendingDeployment, .deploying, .succeeded, .none:
      switch level {
      case .success:
        return CoreL10n.text("保留校验证据")
      case .running:
        return CoreL10n.text("继续观察部署")
      case .failed:
        return CoreL10n.text("处理部署失败")
      case .unknown:
        return CoreL10n.text("补充状态配置")
      }
    }
  }

  public var followUpActionMessage: String {
    switch releaseStatus {
    case .pendingRemoteRecovery:
      return CoreL10n.text("即使本次状态信号正常，也要先确认远端部分写入、冲突路径和恢复包。")
    case .pendingRetry:
      return CoreL10n.text("网络或服务恢复后重新检查部署状态，并保留本次轮询结果。")
    case .failed:
      return CoreL10n.text("打开远端 Actions、Pipeline 或状态端点，修复后重新检查。")
    case .unknown:
      return CoreL10n.text("补齐站点 URL、状态端点或 Token 权限后再检查。")
    case .localOnly:
      return CoreL10n.text("先完成本地提交或线上发布，再进入部署校验。")
    case .pendingReview:
      return CoreL10n.text("先合并或撤回 PR/MR，再继续部署检查。")
    case .pendingDeployment, .deploying, .succeeded, .none:
      switch level {
      case .success:
        return CoreL10n.text("部署状态已正常，保留截图或清单作为发布后校验证据。")
      case .running:
        return CoreL10n.text("保持轮询或稍后手动刷新，直到状态转为正常或失败。")
      case .failed:
        return CoreL10n.text("定位失败信号，修复后重新执行部署检查。")
      case .unknown:
        return CoreL10n.text("补充部署状态配置或检查网络后重新轮询。")
      }
    }
  }
}
