import PublishingWorkbenchCore
import SwiftUI

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
      .accessibilityValue("共 \(orderedHistory.count) 条部署状态记录")

      HStack(spacing: 10) {
        trendLegend("正常", color: WorkbenchTheme.success)
        trendLegend("部署中", color: WorkbenchTheme.progress)
        trendLegend("失败", color: WorkbenchTheme.risk)
        trendLegend("未知", color: .secondary)
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
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
