import Foundation

/// A publish-status decision for one article's current checks. The pending
/// count includes blockers and actionable warnings, excluding optional
/// optimizations; severity describes the strongest outstanding condition.
public struct DraftPublishStatus: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case contentBlocked
    case publishConditionsBlocked
    case warning
    case pending
    case ready
  }

  /// UI checklist items need only their severity and title for this decision.
  public struct Issue: Equatable, Sendable {
    public let severity: PreflightSeverity
    public let title: String
    public let isOptionalOptimization: Bool

    public init(
      severity: PreflightSeverity,
      title: String,
      isOptionalOptimization: Bool = false
    ) {
      self.severity = severity
      self.title = title
      self.isOptionalOptimization = isOptionalOptimization
    }
  }

  public let state: State
  public let pendingCount: Int
  public let severityCount: Int
  public let reason: String?

  public init(
    issues: [Issue],
    pendingCount: Int,
    accountIsBlocked: Bool,
    accountDetail: String?,
    readiness: LocalPublishReadiness?,
    isLoading: Bool = false
  ) {
    self.pendingCount = pendingCount
    let blockers = issues.filter { $0.severity == .error }
    let blockingCount = blockers.count + (accountIsBlocked ? 1 : 0)
    if blockingCount > 0 {
      state = .contentBlocked
      severityCount = blockingCount
      reason =
        Self.firstTitle(in: blockers)
        ?? (accountIsBlocked ? Self.nonempty(accountDetail) : nil)
      return
    }

    let conditions =
      (readiness?.writeBlockingIssues ?? [])
      + (readiness?.commitBlockingIssues ?? [])
    if !conditions.isEmpty {
      state = .publishConditionsBlocked
      severityCount = conditions.count
      reason = Self.firstTitle(
        in: conditions.map {
          Issue(
            severity: $0.severity, title: $0.title,
            isOptionalOptimization: $0.isOptionalOptimization
          )
        })
      return
    }

    if pendingCount > 0 {
      state = .warning
      severityCount = pendingCount
      reason = Self.firstTitle(in: issues)
      return
    }

    guard !isLoading,
      let readiness,
      readiness.writeReadiness != .blocked,
      readiness.commitReadiness != .blocked
    else {
      state = .pending
      severityCount = 0
      reason = nil
      return
    }
    state = .ready
    severityCount = 0
    reason = nil
  }

  private static func firstTitle(in issues: [Issue]) -> String? {
    issues.lazy.compactMap { nonempty($0.title) }.first
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}
