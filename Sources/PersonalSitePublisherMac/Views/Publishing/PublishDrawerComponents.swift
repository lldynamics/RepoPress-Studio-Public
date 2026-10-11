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
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
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

struct PublishDrawerWorkflowStepRow<Action: View>: View {
  let step: PublishDrawerWorkflowStep
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .center, spacing: WorkbenchSpacing.control) {
      ZStack {
        Circle().fill(tint.opacity(0.10))
        if let image {
          Image(systemName: image).font(.caption).foregroundStyle(tint)
        } else {
          Text("\(step.id)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
      }
      .frame(
        width: WorkbenchSpacing.content + WorkbenchSpacing.tight,
        height: WorkbenchSpacing.content + WorkbenchSpacing.tight
      )
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(step.title).font(.callout.weight(.medium))
        Text(step.detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      action().buttonStyle(.link).font(.caption)
    }
    .padding(WorkbenchSpacing.control)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("第 \(step.id) 步：\(step.title)")
    .accessibilityValue(step.detail)
    .accessibilityIdentifier("publish-inspector-step-\(step.id)")
  }

  private var image: String? {
    switch step.status {
    case .pending: nil
    case .passed: "checkmark"
    case .warning: "exclamationmark.triangle"
    case .blocked: "xmark.octagon"
    case .running: "arrow.clockwise"
    }
  }

  private var tint: Color {
    switch step.status {
    case .pending: .secondary
    case .passed: WorkbenchTheme.success
    case .warning: WorkbenchTheme.warning
    case .blocked: WorkbenchTheme.risk
    case .running: WorkbenchTheme.progress
    }
  }
}

struct PublishDrawerFooterAction {
  let title: String
  let systemImage: String
  let identifier: String
  let accessibilityLabel: String
  let accessibilityHint: String?
  let disabledReason: String?
  let perform: () -> Void
}

struct PublishDrawerPrimaryButton: View {
  let action: PublishDrawerFooterAction
  let isSecondary: Bool

  var body: some View {
    let button = Button(action: action.perform) {
      Label(action.title, systemImage: action.systemImage).frame(maxWidth: .infinity)
    }
    .disabled(action.disabledReason != nil)
    .help(action.disabledReason ?? action.title)
    .accessibilityIdentifier(action.identifier)
    .accessibilityLabel(action.accessibilityLabel)
    .accessibilityHint(action.disabledReason ?? action.accessibilityHint ?? "")
    if isSecondary {
      button.buttonStyle(.bordered)
    } else {
      button.workbenchProminentActionStyle()
    }
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
            ForEach(Array(lineDiff.components(separatedBy: "\n").enumerated()), id: \.offset) {
              _, line in
              Text(line.isEmpty ? " " : line)
                .font(.caption.monospaced())
                .foregroundStyle(color(for: line))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(WorkbenchSpacing.card)
          .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
        .background(
          WorkbenchBackgroundStyle.control,
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
          Text(
            "\(diff.kind.localizedDisplayName) · \(diff.status.localizedDisplayName) · \(formattedByteSize)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
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

struct PublishDrawerActionChoice: View {
  let title: String
  let detail: String
  let status: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  var isPrimary: Bool = false
  var actionStyle: PublishDrawerActionStyle = .localSave
  var targetBadge: String? = nil
  var targetBadgeTint: Color? = nil
  let actionTitle: String
  let actionSystemImage: String
  let actionIdentifier: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(tint)
          .accessibilityHidden(true)

        Spacer()

        if let targetBadge {
          Text(targetBadge)
            .font(.workbenchMetadata.weight(.medium))
            .foregroundStyle(targetBadgeTint ?? tint)
            .padding(.horizontal, WorkbenchSpacing.icon)
            .padding(.vertical, 2)
            .background(
              (targetBadgeTint ?? tint).opacity(0.12),
              in: Capsule()
            )
            .lineLimit(1)
        }
      }

      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(status, systemImage: isEnabled ? "checkmark.circle" : "info.circle")
        .font(.caption)
        .foregroundStyle(isEnabled ? tint : .secondary)

      Spacer(minLength: 0)

      if actionStyle == .formalRelease || isPrimary {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
        .accessibilityHint(
          PublishDrawerBatchActionPresentation.accessibilityHint(
            isEnabled: isEnabled,
            status: status
          )
        )
        .help(status)
      } else {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
        .accessibilityHint(
          PublishDrawerBatchActionPresentation.accessibilityHint(
            isEnabled: isEnabled,
            status: status
          )
        )
        .help(status)
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
    .background(
      cardBackground,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(cardBorderStroke, lineWidth: actionStyle == .formalRelease ? 1.5 : 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityValue(status)
  }

  private var cardBackground: AnyShapeStyle {
    if actionStyle == .formalRelease {
      return AnyShapeStyle(WorkbenchTheme.success.opacity(isEnabled ? 0.05 : 0.02))
    }
    return WorkbenchBackgroundStyle.card
  }

  private var cardBorderStroke: Color {
    if actionStyle == .formalRelease {
      return WorkbenchTheme.success.opacity(isEnabled ? 0.5 : 0.2)
    }
    return tint.opacity(isEnabled ? 0.35 : 0.15)
  }
}

struct RemotePublishConfirmationView: View {
  let targetLabel: String
  let targetTitle: String
  var purpose: PublishDrawerRemoteOperationPurpose = .publication
  let preview: RemoteRepositoryPublishPreview
  let reviewDraft: RemoteReviewDraft?
  var batchReview: BatchPublishReviewSnapshot? = nil
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void
  @State private var copyMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Label(purpose.confirmationTitle, systemImage: "checkmark.shield")
          .font(.title3.weight(.semibold))
        Text(purpose.confirmationDetail)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WorkbenchSpacing.page)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          PublishDrawerCard(title: purpose.targetSectionTitle, systemImage: "network") {
            PublishDrawerInfoRow(title: targetLabel, value: targetTitle, systemImage: "doc.text")
            PublishDrawerInfoRow(
              title: "远端", value: preview.repositoryName, systemImage: "shippingbox")
            PublishDrawerInfoRow(
              title: purpose.modeLabel, value: preview.mode.localizedDisplayName,
              systemImage: "arrow.up.circle")
            PublishDrawerInfoRow(
              title: purpose.branchLabel, value: preview.branchName,
              systemImage: "arrow.triangle.branch")
            PublishDrawerInfoRow(
              title: "目标分支", value: preview.targetBranch, systemImage: "arrow.down.to.line")
            PublishDrawerInfoRow(
              title: "权限", value: preview.accessSummary, systemImage: "person.badge.key")
          }

          if preview.mode == .reviewRequest, let reviewDraft {
            PublishDrawerCard(title: "PR/MR 描述", systemImage: "text.page") {
              Text(reviewDraft.title)
                .font(.caption.weight(.semibold))
                .workbenchTruncatedIdentity(reviewDraft.title, lineLimit: 2)
              Text(reviewDraft.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(8)
                .textSelection(.enabled)
              Button {
                ClipboardWriter.copy(
                  reviewDraft.body,
                  successMessage: String(localized: "已复制 PR/MR 描述。"),
                  setMessage: { copyMessage = $0 }
                )
              } label: {
                Label("复制描述", systemImage: "doc.on.doc")
              }
              .controlSize(.small)
              .accessibilityLabel("复制 PR 或 MR 描述")

              if let copyMessage {
                Text(copyMessage)
                  .font(.caption)
                  .foregroundStyle(WorkbenchTheme.success)
                  .accessibilityLabel(copyMessage)
              }
            }
          }

          PublishDrawerCard(title: purpose.fileListTitle, systemImage: "doc.on.doc") {
            if preview.changedPaths.isEmpty {
              Label(purpose.emptyFileMessage, systemImage: "equal.circle")
                .foregroundStyle(.secondary)
            } else {
              ForEach(preview.changedPaths, id: \.self) { path in
                Label(path, systemImage: "doc")
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
              }
            }
          }

          if let batchReview {
            PublishDrawerCard(title: "完整批次文章与差异", systemImage: "doc.text.magnifyingglass") {
              Text("以下为本次确认的全部文章；差异以本地仓库为基线，远端版本仍会在写入前预检。")
                .font(.caption)
                .foregroundStyle(.secondary)
              if batchReview.excludedCleanupCount > 0 {
                Label(
                  String(
                    format: String(localized: "%d 个待下线请求未纳入本次发布，请到回收站单独处理。"),
                    batchReview.excludedCleanupCount),
                  systemImage: "info.circle"
                )
                .font(.caption)
              }
              ForEach(batchReview.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                  Text(item.draftTitle).font(.headline)
                  Text(item.markdownPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                  ForEach(Array(item.preview.changedFileDiffs.enumerated()), id: \.element.id) {
                    index, diff in
                    PublishDrawerFileDiffRow(diff: diff, isExpandedInitially: index == 0)
                  }
                }
              }
            }
            .accessibilityIdentifier("publish-batch-review-diffs")
          }

          if !preview.warningIssues.isEmpty {
            PublishDrawerCard(title: purpose.warningTitle, systemImage: "exclamationmark.triangle")
            {
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
        .padding(WorkbenchSpacing.page)
      }

      Divider()

      HStack {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text(purpose.footerSummary(fileCount: preview.changedPaths.count))
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          confirmAction()
        } label: {
          Label(purpose.confirmActionTitle, systemImage: "paperplane.fill")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!preview.canPublish || preview.changedPaths.isEmpty || isPublishing)
        .accessibilityHint(purpose.confirmAccessibilityHint)
        .accessibilityIdentifier("remote-publish-confirm")
      }
      .padding(WorkbenchSpacing.content)
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
