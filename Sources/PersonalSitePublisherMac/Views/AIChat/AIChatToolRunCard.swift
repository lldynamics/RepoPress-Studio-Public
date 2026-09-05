import PublishingWorkbenchCore
import SwiftUI

struct AIChatToolRunCard: View {
  let runs: [WorkbenchAIAgentToolRunRecord]
  @State private var expandedRunIDs: Set<String> = []
  @State private var copyStatus: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(String(localized: "Agent 工具记录"), systemImage: "wrench.and.screwdriver")
        .font(.workbenchCardTitle)
        .foregroundStyle(.secondary)

      VStack(spacing: 0) {
        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
          runRow(run)
          if index < runs.count - 1 {
            Divider()
              .padding(.leading, 31)
          }
        }
      }
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(.separator.opacity(0.65), lineWidth: 1)
      }
      if let copyStatus {
        Text(copyStatus)
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "Agent 工具记录"))
  }

  private func runRow(_ run: WorkbenchAIAgentToolRunRecord) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: statusImage(run.status))
        .font(.caption.weight(.semibold))
        .foregroundStyle(statusColor(run.status))
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(toolTitle(run))
            .font(.callout.weight(.medium))
          Text(statusTitle(run.status))
            .font(.workbenchMetadata.weight(.semibold))
            .foregroundStyle(statusColor(run.status))
          Spacer(minLength: 4)
          if let elapsed = elapsedTitle(run) {
            Text(elapsed)
              .font(.workbenchMetadata.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
        }

        let summary = run.summary.nilIfEmpty ?? fallbackSummary(run.status)
        let isExpanded = expandedRunIDs.contains(run.id)
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(isExpanded ? nil : 4)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        if run.status == .failed, !summary.isEmpty {
          HStack(spacing: 10) {
            Button(isExpanded ? String(localized: "收起摘要") : String(localized: "展开摘要")) {
              if isExpanded {
                expandedRunIDs.remove(run.id)
              } else {
                expandedRunIDs.insert(run.id)
              }
            }
            .buttonStyle(.borderless)
            .font(.workbenchMetadata)
            .accessibilityLabel(
              isExpanded
                ? String(localized: "收起工具失败摘要") : String(localized: "展开工具失败摘要")
            )
            .accessibilityHint("显示当前已保存的完整摘要")

            Button("复制完整摘要") {
              _ = ClipboardWriter.copy(
                summary,
                successMessage: String(localized: "已复制完整工具摘要。"),
                setMessage: { copyStatus = $0 }
              )
            }
            .buttonStyle(.borderless)
            .font(.workbenchMetadata)
            .accessibilityLabel("复制完整工具失败摘要")
            .accessibilityHint("复制当前已保存的完整摘要")
          }
        }

      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
  }

  private func toolTitle(_ run: WorkbenchAIAgentToolRunRecord) -> String {
    if let command = WorkbenchAutomationAgentToolRegistry.command(for: run.toolID) {
      return WorkbenchAutomationRegistry.descriptor(for: command)?.title ?? command.rawValue
    }
    return run.modelToolName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? run.toolID.rawValue
  }

  private func statusTitle(_ status: WorkbenchAIAgentToolRunStatus) -> LocalizedStringKey {
    switch status {
    case .awaitingConfirmation:
      return "等待确认"
    case .succeeded:
      return "已完成"
    case .failed:
      return "失败"
    case .cancelled:
      return "已停止"
    case .rejected:
      return "已拒绝"
    }
  }

  private func fallbackSummary(_ status: WorkbenchAIAgentToolRunStatus) -> String {
    switch status {
    case .awaitingConfirmation:
      return String(localized: "尚未执行，等待你确认。")
    case .succeeded:
      return String(localized: "工具已完成。")
    case .failed:
      return String(localized: "工具未能完成。")
    case .cancelled:
      return String(localized: "工具调用已取消。")
    case .rejected:
      return String(localized: "用户已拒绝此工具调用，未执行。")
    }
  }

  private func statusImage(_ status: WorkbenchAIAgentToolRunStatus) -> String {
    switch status {
    case .awaitingConfirmation:
      return "hand.raised.fill"
    case .succeeded:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.octagon.fill"
    case .cancelled:
      return "slash.circle"
    case .rejected:
      return "hand.raised.slash.fill"
    }
  }

  private func statusColor(_ status: WorkbenchAIAgentToolRunStatus) -> Color {
    switch status {
    case .awaitingConfirmation:
      return WorkbenchTheme.warning
    case .succeeded:
      return WorkbenchTheme.success
    case .failed:
      return WorkbenchTheme.risk
    case .cancelled:
      return .secondary
    case .rejected:
      return WorkbenchTheme.risk
    }
  }

  private func elapsedTitle(_ run: WorkbenchAIAgentToolRunRecord) -> String? {
    guard let completedAt = run.completedAt else { return nil }
    let elapsed = max(0, completedAt.timeIntervalSince(run.startedAt))
    return String(format: "%.1fs", elapsed)
  }
}
