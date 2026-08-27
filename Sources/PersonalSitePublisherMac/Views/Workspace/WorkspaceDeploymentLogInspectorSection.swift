import AppKit
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
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Label("SSG / 构建失败详情", systemImage: "xmark.octagon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkbenchTheme.risk)
              Spacer()
              CopyLogButton(
                text: fullLogPayload(for: primaryFailure),
                label: "复制错误堆栈"
              )
            }

            if let location = primaryFailure.locationText {
              Text(location)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            DeploymentLogCodeBlock(
              message: primaryFailure.message,
              level: .error
            )
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
            VStack(alignment: .leading, spacing: 10) {
              ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
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
                    Spacer()
                    CopyLogButton(
                      text: fullLogPayload(for: entry),
                      label: "复制"
                    )
                  }

                  DeploymentLogCodeBlock(
                    message: entry.message,
                    level: entry.level
                  )
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

  private func fullLogPayload(for entry: DeploymentLogEntry) -> String {
    if let location = entry.locationText {
      return "[\(entry.source)] \(location)\n\(entry.message)"
    }
    return "[\(entry.source)] \(entry.message)"
  }
}

private struct CopyLogButton: View {
  let text: String
  var label: LocalizedStringKey = "复制"
  @State private var isCopied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      isCopied = true
      Task {
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        isCopied = false
      }
    } label: {
      Label(
        isCopied ? "已复制" : label,
        systemImage: isCopied ? "checkmark" : "doc.on.doc"
      )
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .foregroundStyle(isCopied ? WorkbenchTheme.success : WorkbenchTheme.documentForeground)
    .controlSize(.small)
    .accessibilityLabel(label)
  }
}

private struct DeploymentLogCodeBlock: View {
  let message: String
  let level: DeploymentLogLevel

  private var lines: [String] {
    let split = message.components(separatedBy: .newlines)
    return split.isEmpty ? [""] : split
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
        let isError = isErrorHighlight(line, overallLevel: level)
        DeploymentLogRow(
          lineNumber: idx + 1,
          line: line,
          isErrorLine: isError
        )
      }
    }
    .padding(6)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .stroke(
          level == .error ? WorkbenchTheme.risk.opacity(0.25) : Color.primary.opacity(0.08),
          lineWidth: 1
        )
    }
  }

  private func isErrorHighlight(_ line: String, overallLevel: DeploymentLogLevel) -> Bool {
    let lower = line.lowercased()
    if lower.contains("error:") || lower.contains("fatal:") || lower.contains("failed") || lower.contains("exception") {
      return true
    }
    return overallLevel == .error && lines.count == 1
  }
}

private struct DeploymentLogRow: View {
  let lineNumber: Int
  let line: String
  let isErrorLine: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Text("\(lineNumber)")
        .font(.workbenchMetadata.monospacedDigit())
        .foregroundStyle(isErrorLine ? WorkbenchTheme.risk.opacity(0.8) : Color.secondary.opacity(0.6))
        .frame(width: 22, alignment: .trailing)
        .padding(.trailing, 2)

      Text(line.isEmpty ? " " : line)
        .font(.caption.monospaced())
        .foregroundStyle(isErrorLine ? WorkbenchTheme.risk : Color.primary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 1)
    .background(
      isErrorLine
        ? WorkbenchTheme.risk.opacity(0.12)
        : Color.clear,
      in: RoundedRectangle(cornerRadius: 3)
    )
  }
}
