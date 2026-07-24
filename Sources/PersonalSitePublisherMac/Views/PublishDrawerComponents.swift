import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(LocalizedStringKey(title), systemImage: systemImage)
        .font(.callout.weight(.semibold))

      content

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
    .accessibilityHint("发布流程步骤内容")
  }
}

struct PublishDrawerStat: View {
  let title: String
  let value: String
  let systemImage: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(LocalizedStringKey(title), systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
    .accessibilityValue(value)
  }
}

struct PublishDrawerInfoRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value)
        .workbenchTruncatedIdentity(value)
    }
    .font(.caption)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
    .accessibilityValue(value)
  }
}

struct PublishDrawerFileDiffRow: View {
  let diff: PublishFileDiff
  @State private var isExpanded: Bool

  init(diff: PublishFileDiff, isExpandedInitially: Bool) {
    self.diff = diff
    _isExpanded = State(initialValue: isExpandedInitially)
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if let lineDiff = diff.lineDiff?.nilIfEmpty {
        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lineDiff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
              Text(line.isEmpty ? " " : line)
                .font(.caption.monospaced())
                .foregroundStyle(color(for: line))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(10)
          .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
        .background(
          WorkbenchBackgroundStyle.codeBlock,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .accessibilityLabel("\(diff.path) 的逐行差异")
      } else {
        Label("此文件没有可显示的文本行差异。", systemImage: "doc")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: diff.status.publishDrawerSystemImage)
          .foregroundStyle(diff.status.publishDrawerColor)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          WorkbenchPathIdentity(path: diff.path)
          Text("\(diff.kind.localizedDisplayName) · \(diff.status.localizedDisplayName) · \(formattedByteSize)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(9)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  private var formattedByteSize: String {
    ByteCountFormatter.string(fromByteCount: diff.byteSize, countStyle: .file)
  }

  private func color(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") {
      return WorkbenchTheme.success
    }
    if line.hasPrefix("-") && !line.hasPrefix("---") {
      return WorkbenchTheme.risk
    }
    return .secondary
  }
}

struct RemotePublishConfirmationView: View {
  let targetLabel: String
  let targetTitle: String
  let preview: RemoteRepositoryPublishPreview
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Label("最终发布确认", systemImage: "checkmark.shield")
          .font(.title3.weight(.semibold))
        Text("请确认远端、分支、发布方式和完整文件清单。确认后会立即写入远端。")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          PublishDrawerCard(title: "发布目标", systemImage: "network") {
            PublishDrawerInfoRow(title: targetLabel, value: targetTitle, systemImage: "doc.text")
            PublishDrawerInfoRow(title: "远端", value: preview.repositoryName, systemImage: "shippingbox")
            PublishDrawerInfoRow(title: "模式", value: preview.mode.localizedDisplayName, systemImage: "arrow.up.circle")
            PublishDrawerInfoRow(title: "发布分支", value: preview.branchName, systemImage: "arrow.triangle.branch")
            PublishDrawerInfoRow(title: "目标分支", value: preview.targetBranch, systemImage: "arrow.down.to.line")
            PublishDrawerInfoRow(title: "权限", value: preview.accessSummary, systemImage: "person.badge.key")
          }

          PublishDrawerCard(title: "完整文件清单", systemImage: "doc.on.doc") {
            if preview.changedPaths.isEmpty {
              Label("没有待发布文件。", systemImage: "equal.circle")
                .foregroundStyle(.secondary)
            } else {
              ForEach(preview.changedPaths, id: \.self) { path in
                Label(path, systemImage: "doc")
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
              }
            }
          }

          if !preview.warningIssues.isEmpty {
            PublishDrawerCard(title: "发布警告", systemImage: "exclamationmark.triangle") {
              ForEach(preview.warningIssues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                  Text(issue.title)
                    .font(.caption.weight(.semibold))
                  Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                }
              }
            }
          }
        }
        .padding(20)
      }

      Divider()

      HStack {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text("将发布 \(preview.changedPaths.count) 个文件")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          confirmAction()
        } label: {
          Label("确认线上发布", systemImage: "paperplane.fill")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!preview.canPublish || preview.changedPaths.isEmpty || isPublishing)
        .accessibilityHint("确认后立即执行远端发布")
      }
      .padding(16)
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 660)
  }
}

extension PreflightSeverity {
  var publishDrawerSystemImage: String {
    switch self {
    case .error:
      return "xmark.octagon"
    case .warning:
      return "exclamationmark.triangle"
    case .info:
      return "checkmark.circle"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return WorkbenchTheme.success
    }
  }
}

extension PublishFileDiffStatus {
  var publishDrawerSystemImage: String {
    switch self {
    case .added:
      return "plus.circle"
    case .modified:
      return "pencil.circle"
    case .deleted:
      return "trash.circle"
    case .unchanged:
      return "equal.circle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    case .unsafePath:
      return "xmark.octagon"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .added:
      return WorkbenchTheme.success
    case .modified:
      return WorkbenchTheme.warning
    case .deleted:
      return WorkbenchTheme.risk
    case .unchanged:
      return .secondary
    case .missingSource, .unsafePath:
      return WorkbenchTheme.risk
    }
  }
}

struct PublishDrawerFlowStep: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
  let systemImage: String
  let state: PublishDrawerFlowStepState
}

struct PublishDrawerFinalAction {
  let title: String
  let summary: String
  let systemImage: String
  let isDeploymentSuccessful: Bool
}

enum PublishDrawerFlowCard: CaseIterable, Hashable, Identifiable {
  case checks
  case diff
  case write
  case remote
  case deployment

  var id: Self { self }

  var title: String {
    switch self {
    case .checks:
      return "检查"
    case .diff:
      return WorkbenchUITerminology.difference
    case .write:
      return "写入"
    case .remote:
      return "远端"
    case .deployment:
      return "部署"
    }
  }
}

enum PublishDrawerFlowStepState: Equatable {
  case complete
  case active
  case blocked
  case pending

  var color: Color {
    switch self {
    case .complete:
      return WorkbenchTheme.success
    case .active:
      return WorkbenchTheme.progress
    case .blocked:
      return WorkbenchTheme.risk
    case .pending:
      return .secondary
    }
  }

  var connectorColor: Color {
    switch self {
    case .complete, .active:
      return color.opacity(0.75)
    case .blocked, .pending:
      return Color(nsColor: .separatorColor)
    }
  }

  var backgroundColor: Color {
    switch self {
    case .complete:
      return WorkbenchTheme.success.opacity(0.10)
    case .active:
      return WorkbenchTheme.progress.opacity(0.12)
    case .blocked:
      return WorkbenchTheme.risk.opacity(0.10)
    case .pending:
      return Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }
  }

  var borderColor: Color {
    switch self {
    case .active:
      return WorkbenchTheme.progress.opacity(0.55)
    case .blocked:
      return WorkbenchTheme.risk.opacity(0.45)
    case .complete:
      return WorkbenchTheme.success.opacity(0.35)
    case .pending:
      return Color(nsColor: .separatorColor).opacity(0.45)
    }
  }
}
