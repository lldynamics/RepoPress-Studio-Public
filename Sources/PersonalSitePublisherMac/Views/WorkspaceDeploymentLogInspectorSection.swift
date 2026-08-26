import PublishingWorkbenchCore
import SwiftUI

/// Surfaces the current article's deployment failure in the Checks Inspector.
/// Provider input is already bounded and redacted by `DeploymentStatusSignal`.
struct WorkspaceDeploymentLogInspectorSection: View {
  let snapshot: DeploymentStatusSnapshot

  private var entries: [DeploymentLogEntry] {
    snapshot.signals
      .flatMap(\.logExcerpt)
      .sorted { priority($0.level) > priority($1.level) }
  }

  private var primaryFailure: DeploymentLogEntry? {
    entries.first(where: { $0.level == .error })
  }

  var body: some View {
    InspectorSection("部署构建") {
      VStack(alignment: .leading, spacing: 8) {
        Label(snapshot.message, systemImage: snapshot.level.systemImage)
          .font(.caption.weight(.medium))
          .foregroundStyle(statusColor)
          .fixedSize(horizontal: false, vertical: true)

        if let primaryFailure {
          VStack(alignment: .leading, spacing: 4) {
            Label("SSG / 构建失败详情", systemImage: "xmark.octagon")
              .font(.caption.weight(.semibold))
              .foregroundStyle(WorkbenchTheme.risk)
            if let location = primaryFailure.locationText {
              Text(location)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Text(primaryFailure.message)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            WorkbenchTheme.risk.opacity(0.08),
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
        }

        if entries.isEmpty {
          Text("部署状态尚未返回构建日志摘录。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          DisclosureGroup("全部日志摘录（\(entries.count) 条）") {
            VStack(alignment: .leading, spacing: 7) {
              ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                  HStack(spacing: 5) {
                    Image(systemName: entry.level.systemImage)
                      .foregroundStyle(color(for: entry.level))
                    Text(entry.source)
                      .font(.caption.weight(.medium))
                    if let location = entry.locationText {
                      Text(location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                  }
                  Text(entry.message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            .padding(.top, 5)
          }
          .font(.caption)
        }
      }
    }
    .accessibilityIdentifier("workspace-inspector-deployment-logs")
  }

  private var statusColor: Color {
    switch snapshot.level {
    case .failed:
      WorkbenchTheme.risk
    case .running:
      WorkbenchTheme.warning
    case .success:
      WorkbenchTheme.success
    case .unknown:
      .secondary
    }
  }

  private func priority(_ level: DeploymentLogLevel) -> Int {
    switch level {
    case .error: 3
    case .warning: 2
    case .info: 1
    }
  }

  private func color(for level: DeploymentLogLevel) -> Color {
    switch level {
    case .error: WorkbenchTheme.risk
    case .warning: WorkbenchTheme.warning
    case .info: .secondary
    }
  }
}
