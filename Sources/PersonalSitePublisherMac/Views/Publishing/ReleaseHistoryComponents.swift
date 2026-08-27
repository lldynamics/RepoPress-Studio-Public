import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ReleaseHistoryFailureGroup: Identifiable {
  let cause: String
  let entries: [ReleaseLedgerEntry]

  var id: String { cause }
  var latestDate: Date { entries.map(\.record.createdAt).max() ?? .distantPast }

  var affectedObjectSummary: String {
    let objects = entries.compactMap { entry in
      entry.record.markdownPath?.nilIfEmpty
        ?? entry.record.draftTitle?.nilIfEmpty
        ?? entry.record.siteName?.nilIfEmpty
    }
    let uniqueObjects = Array(NSOrderedSet(array: objects)).compactMap { $0 as? String }
    guard !uniqueObjects.isEmpty else { return "涉及发布记录" }
    if uniqueObjects.count == 1 { return uniqueObjects[0] }
    return "\(uniqueObjects[0]) 等 \(uniqueObjects.count) 项"
  }
}

enum ReleaseHistoryRecordPresentation: Identifiable {
  case failureGroup(ReleaseHistoryFailureGroup)
  case entry(ReleaseLedgerEntry)

  var id: String {
    switch self {
    case let .failureGroup(group):
      return "failure-group:\(group.id)"
    case let .entry(entry):
      return "entry:\(entry.id.uuidString)"
    }
  }
}

enum ReleaseHistoryPresentation {
  static func records(for entries: [ReleaseLedgerEntry]) -> [ReleaseHistoryRecordPresentation] {
    let groupedFailures = Dictionary(grouping: entries.filter(isFailure), by: failureCause)
    let retainedGroups = groupedFailures.filter { $0.value.count > 1 }
    var emittedCauses = Set<String>()

    return entries.compactMap { entry in
      let cause = failureCause(entry)
      if isFailure(entry), let groupEntries = retainedGroups[cause] {
        guard emittedCauses.insert(cause).inserted else { return nil }
        return .failureGroup(ReleaseHistoryFailureGroup(cause: cause, entries: groupEntries))
      }
      return .entry(entry)
    }
  }

  static func failureCause(_ entry: ReleaseLedgerEntry) -> String {
    if let signal = entry.deploymentStatus?.signals.first(where: { $0.level == .failed }) {
      if let log = signal.logExcerpt.first(where: { $0.level == .error })?.message.nilIfEmpty {
        return stableSummary(log)
      }
      if let message = signal.message.nilIfEmpty {
        return stableSummary(message)
      }
      if let title = signal.title.nilIfEmpty {
        return stableSummary(title)
      }
    }
    if let deploymentMessage = entry.deploymentStatus?.message.nilIfEmpty {
      return stableSummary(deploymentMessage)
    }
    if let message = entry.statusMessage.nilIfEmpty {
      return stableSummary(message)
    }
    return stableSummary(entry.record.summary.nilIfEmpty ?? entry.record.title)
  }

  private static func isFailure(_ entry: ReleaseLedgerEntry) -> Bool {
    entry.status == .failed || entry.deploymentStatus?.level == .failed
  }

  private static func stableSummary(_ value: String) -> String {
    let normalized = value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return String(normalized.prefix(140))
  }
}

struct DeploymentStatusTrendChart: View {
  var history: [DeploymentStatusSnapshot]

  private var orderedHistory: [DeploymentStatusSnapshot] {
    history.sorted { $0.checkedAt < $1.checkedAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("部署趋势", systemImage: "chart.bar.xaxis")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(alignment: .bottom, spacing: 5) {
        ForEach(orderedHistory) { snapshot in
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar)
            .fill(color(for: snapshot.level))
            .frame(width: 18, height: height(for: snapshot.level))
            .help("\(snapshot.checkedAt.workbenchShortText) · \(snapshot.level.localizedDisplayName) · \(snapshot.message)")
            .accessibilityLabel("\(snapshot.checkedAt.workbenchShortText) 的部署状态")
            .accessibilityValue("\(snapshot.level.localizedDisplayName)：\(snapshot.message)")
        }
      }
      .frame(height: 42, alignment: .bottom)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("部署趋势")
      .accessibilityValue(
        String(localized: "共 \(orderedHistory.count) 条部署状态记录")
      )

      HStack(spacing: 10) {
        trendLegend("正常", color: WorkbenchTheme.success)
        trendLegend("部署中", color: WorkbenchTheme.progress)
        trendLegend("失败", color: WorkbenchTheme.risk)
        trendLegend("未知", color: .secondary)
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func height(for level: DeploymentStatusLevel) -> CGFloat {
    switch level {
    case .success:
      return 34
    case .running:
      return 24
    case .failed:
      return 34
    case .unknown:
      return 16
    }
  }

  private func color(for level: DeploymentStatusLevel) -> Color {
    switch level {
    case .success:
      return WorkbenchTheme.success
    case .running:
      return WorkbenchTheme.progress
    case .failed:
      return WorkbenchTheme.risk
    case .unknown:
      return .secondary
    }
  }

  private func trendLegend(_ title: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

enum DangerousReleaseAction: Identifiable {
  case resumeReview(ReleaseRecord)
  case withdrawReview(ReleaseRecord)
  case rollbackRemote(ReleaseRecord)

  var id: String {
    switch self {
    case let .resumeReview(record):
      return "resume-review-\(record.id)"
    case let .withdrawReview(record):
      return "withdraw-\(record.id)"
    case let .rollbackRemote(record):
      return "rollback-\(record.id)"
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .resumeReview:
      return "继续创建 PR/MR"
    case .withdrawReview:
      return "确认撤回 Review"
    case .rollbackRemote:
      return "确认执行回滚"
    }
  }

  var confirmationMessage: String {
    switch self {
    case let .resumeReview(record):
      return "将复用远端分支 \(record.branchName ?? "-") 与已写入的 commit，仅创建或获取 PR/MR，不会重新上传文件或自动合并。"
    case let .withdrawReview(record):
      return "将通过远端 API 关闭这条 PR/MR：\(record.reviewTitle ?? record.title)。这个操作会影响线上 Review 流程。"
    case let .rollbackRemote(record):
      return "将通过远端 API 为提交 \(record.shortCommitSHA ?? record.commitSHA ?? record.title) 创建回滚 commit。执行前请确认当前线上状态。"
    }
  }

  var buttonRole: ButtonRole? {
    switch self {
    case .resumeReview:
      return nil
    case .withdrawReview, .rollbackRemote:
      return .destructive
    }
  }
}
