import PublishingWorkbenchCore
import SwiftUI

struct OnlineSiteInspectionSection: View {
  let report: SiteMaintenanceReport
  let latestRelease: ReleaseRecord?
  let deploymentSnapshot: DeploymentStatusSnapshot?
  let canCheckDeployment: Bool
  let isChecking: Bool
  let message: String?
  let runInspection: () -> Void

  private var linkErrorCount: Int {
    report.linkAuditItems.filter { $0.severity == .error }.count
  }

  private var linkWarningCount: Int {
    report.linkAuditItems.filter { $0.severity == .warning }.count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Label("线上巡检", systemImage: "dot.radiowaves.left.and.right")
            .font(.headline)
          Text("手动复用部署状态、站点/文章页检查、内容健康与链接审计。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          runInspection()
        } label: {
          Label(isChecking ? "正在巡检" : "运行巡检", systemImage: "arrow.clockwise")
        }
        .disabled(isChecking || latestRelease == nil || !canCheckDeployment)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
        MetricTile(
          title: "线上状态",
          value: deploymentSnapshot?.level.localizedDisplayName ?? "未检查",
          semantic: deploymentSnapshot.map { deploymentSemantic($0.level) } ?? .neutral
        )
        MetricTile(
          title: "内容健康",
          value: "\(report.healthSummary.score)/100",
          semantic: healthSemantic(report.healthSummary.level)
        )
        MetricTile(
          title: "链接错误",
          value: "\(linkErrorCount)",
          semantic: linkErrorCount == 0 ? .passed : .blocking
        )
        MetricTile(
          title: "链接警告",
          value: "\(linkWarningCount)",
          semantic: linkWarningCount == 0 ? .passed : .warning
        )
      }

      if let deploymentSnapshot {
        Label(
          "\(deploymentSnapshot.provider.localizedDisplayName)：\(deploymentSnapshot.message)",
          systemImage: deploymentSnapshot.level.systemImage
        )
        .font(.caption)
        .foregroundStyle(statusColor(deploymentSnapshot.level))
      } else if latestRelease == nil {
        Label("尚无发布记录，完成一次发布后才能巡检线上站点。", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !canCheckDeployment {
        Label("请在设置中填写站点 URL 或部署状态端点，才能执行线上检查。", systemImage: "gearshape")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func statusColor(_ level: DeploymentStatusLevel) -> Color {
    switch level {
    case .success: WorkbenchTheme.success
    case .running: WorkbenchTheme.warning
    case .failed: WorkbenchTheme.risk
    case .unknown: .secondary
    }
  }

  private func deploymentSemantic(_ level: DeploymentStatusLevel) -> MetricTileSemantic {
    switch level {
    case .success: .passed
    case .running: .progress
    case .failed: .blocking
    case .unknown: .neutral
    }
  }

  private func healthSemantic(_ level: SiteMaintenanceHealthLevel) -> MetricTileSemantic {
    switch level {
    case .stable: .passed
    case .watch: .progress
    case .needsWork: .warning
    case .urgent: .blocking
    }
  }
}
