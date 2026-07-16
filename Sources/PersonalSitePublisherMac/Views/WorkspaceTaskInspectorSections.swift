import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskMetadataState {
  let siteName: String
  let markdownPath: String

  init(draft: ArticleDraft, profile: SiteProfile) {
    siteName = profile.name
    markdownPath = profile.markdownPath(for: draft)
  }
}

struct WorkspaceTaskMetadataSection: View {
  @Binding var draft: ArticleDraft
  let state: WorkspaceTaskMetadataState
  @State private var isSupplementaryMetadataExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      InspectorSection("基础字段") {
        TextField("Title", text: $draft.title)
          .accessibilityLabel("文章标题")
          .accessibilityValue(draft.title.isEmpty ? "未填写" : draft.title)
        TextField("Slug", text: $draft.slug)
          .accessibilityLabel("文章 Slug")
          .accessibilityValue(draft.slug.isEmpty ? "未填写" : draft.slug)
        TextField("Summary", text: $draft.summary, axis: .vertical)
          .lineLimit(2...5)
          .accessibilityLabel("文章摘要")
          .accessibilityValue(draft.summary.isEmpty ? "未填写" : draft.summary)
      }

      InspectorSection("分类") {
        TextField("Tags", text: tagsBinding)
          .accessibilityLabel("文章标签")
          .accessibilityValue(draft.tags.isEmpty ? "未填写" : draft.tags.joined(separator: "，"))
        TextField("Categories", text: categoriesBinding)
          .accessibilityLabel("文章分类")
          .accessibilityValue(draft.categories.isEmpty ? "未填写" : draft.categories.joined(separator: "，"))
      }

      DisclosureGroup(isExpanded: $isSupplementaryMetadataExpanded) {
        VStack(alignment: .leading, spacing: 14) {
          InspectorSection("发布时间与可见性") {
            DatePicker("Date", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
              .accessibilityLabel("文章日期")
              .accessibilityValue(draft.date.formatted(date: .abbreviated, time: .shortened))
            Picker("Visibility", selection: $draft.visibility) {
              ForEach(ArticleVisibility.allCases) { visibility in
                Label(visibility.localizedDisplayName, systemImage: visibility.systemImage)
                  .tag(visibility)
              }
            }
            .accessibilityLabel("文章可见性")
            .accessibilityValue(draft.visibility.localizedDisplayName)
            Toggle("Draft", isOn: $draft.draft)
              .accessibilityLabel("草稿状态")
              .accessibilityValue(draft.draft ? "草稿" : "非草稿")
          }

          InspectorSection("作者") {
            TextField("Authors", text: authorsBinding)
              .accessibilityLabel("文章作者")
              .accessibilityValue(draft.authors.isEmpty ? "未填写" : draft.authors.joined(separator: "，"))
          }

          InspectorSection("发布路径") {
            InspectorStatRow(title: "站点", value: state.siteName, systemImage: "globe")
            InspectorStatRow(title: "状态", value: draft.status.localizedDisplayName, systemImage: draft.status.systemImage)
            Text(state.markdownPath)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .textSelection(.enabled)
          }
        }
        .padding(.top, 2)
      } label: {
        Label("补充元数据", systemImage: "ellipsis.circle")
          .font(.callout.weight(.medium))
      }
    }
  }

  private var tagsBinding: Binding<String> {
    Binding(
      get: { draft.tags.commaSeparated },
      set: { draft.tags = parseList($0) }
    )
  }

  private var categoriesBinding: Binding<String> {
    Binding(
      get: { draft.categories.commaSeparated },
      set: { draft.categories = parseList($0) }
    )
  }

  private var authorsBinding: Binding<String> {
    Binding(
      get: { draft.authors.commaSeparated },
      set: { draft.authors = parseList($0) }
    )
  }

  private func parseList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

struct WorkspaceTaskSEOSection: View {
  let draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.seoReport(for: draft)
    let snapshot = store.seoSocialPreviewSnapshot(for: draft)
    let cachePresentation = store.seoSocialPreviewCachePresentation(for: draft)

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("SEO 摘要") {
        InspectorStatRow(title: "状态", value: report.statusTitle, systemImage: "chart.bar.doc.horizontal")
        InspectorStatRow(title: "标题", value: "\(report.titleCharacterCount) 字", systemImage: "textformat.size")
        InspectorStatRow(title: "摘要", value: "\(report.summaryCharacterCount) 字", systemImage: "text.alignleft")
        InspectorStatRow(title: "H1", value: "\(report.h1Count)", systemImage: "number")

        HStack {
          Button {
            store.refreshSEOSocialPreview(for: draft)
          } label: {
            Label(cachePresentation.manualRefreshTitle, systemImage: "arrow.clockwise")
          }
        }
        .controlSize(.small)

        Label(cachePresentation.message, systemImage: cachePresentation.state.systemImage)
          .font(.caption)
          .foregroundStyle(cachePresentation.needsManualRefresh ? .orange : .secondary)
      }

      InspectorSection("问题") {
        ForEach(report.findings.prefix(6)) { finding in
          seoFindingRow(finding)
        }
      }

      InspectorSection("社交预览") {
        if let snapshot {
          InspectorStatRow(title: "标题", value: "\(snapshot.titleCharacterCount) 字", systemImage: "textformat.size")
          InspectorStatRow(title: "描述", value: "\(snapshot.descriptionCharacterCount) 字", systemImage: "text.alignleft")
          InspectorStatRow(title: "图片", value: snapshot.imageDimensions?.workbenchDimensionText ?? (snapshot.imagePath == nil ? "未设置" : "已设置"), systemImage: "photo")
          Text(snapshot.canonicalURLText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)

          socialPreviewReadinessSection(snapshot)
          socialShareCopySection(snapshot.socialShareCopyItems)
          socialDebugLinkSection(snapshot.externalDebugLinks)

          ForEach(snapshot.cards) { card in
            VStack(alignment: .leading, spacing: 5) {
              Label(card.kind.localizedDisplayName, systemImage: card.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              HStack(spacing: 8) {
                Label(card.titleBudgetText, systemImage: card.isTitleWithinBudget ? "checkmark.circle" : "exclamationmark.triangle")
                  .foregroundStyle(card.isTitleWithinBudget ? Color.secondary : WorkbenchTheme.warning)
                Label(card.descriptionBudgetText, systemImage: card.isDescriptionWithinBudget ? "checkmark.circle" : "exclamationmark.triangle")
                  .foregroundStyle(card.isDescriptionWithinBudget ? Color.secondary : WorkbenchTheme.warning)
                if let imageAspectRatio = card.imageAspectRatio {
                  Label(imageAspectRatio, systemImage: "aspectratio")
                    .foregroundStyle(.secondary)
                }
                if let imageDimensions = card.imageDimensions {
                  Label(imageDimensions.workbenchDimensionText, systemImage: "ruler")
                    .foregroundStyle(.secondary)
                }
              }
              .font(.caption2)
              Text(card.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
              Text(card.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
            .padding(8)
            .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
          }
        } else {
          Text("还没有社交预览快照。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      relatedArticleSuggestionSection

      InspectorSection("Front Matter 预览") {
        Text(report.frontMatterPreview)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(16)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }

      if let message = store.seoSocialPreviewMessage {
        actionMessage(message)
      }
    }
  }

  @ViewBuilder
  private var relatedArticleSuggestionSection: some View {
    let suggestions = store.relatedArticleSuggestions(for: draft, limit: 3)
    if !suggestions.isEmpty {
      InspectorSection("关联文章建议") {
        VStack(alignment: .leading, spacing: 9) {
          ForEach(suggestions) { suggestion in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                  .foregroundStyle(.secondary)
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(suggestion.targetTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                  Text(suggestion.targetPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }

              Text(suggestion.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

              if !suggestion.sharedLabels.isEmpty {
                Text(suggestion.sharedLabels.joined(separator: "、"))
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }

              HStack {
                Button {
                  store.selectDraft(suggestion.targetDraftID)
                } label: {
                  Label("打开目标", systemImage: "arrow.forward.circle")
                }
              }
              .controlSize(.small)
            }
            .padding(8)
            .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
          }
        }
      }
    }
  }

  private func socialPreviewReadinessSection(_ snapshot: SEOSocialPreviewSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("平台就绪度", systemImage: "checklist.checked")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(snapshot.socialShareChecklistMarkdown, message: "已复制 SEO / Social 检查清单。")
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制 SEO / Social 检查清单")
        .accessibilityLabel("复制 SEO Social 检查清单")

        Button {
          copy(snapshot.metaTags.htmlBlock, message: "已复制社交预览 Meta HTML。")
        } label: {
          Image(systemName: "curlybraces")
        }
        .buttonStyle(.borderless)
        .disabled(snapshot.metaTags.isEmpty)
        .help("复制 Meta HTML")
        .accessibilityLabel("复制社交预览 Meta HTML")
      }

      ForEach(snapshot.platformReadiness) { item in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: item.status.systemImage)
            .foregroundStyle(socialPreviewReadinessForeground(item.status))
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(item.kind.localizedDisplayName)
                .font(.caption.weight(.semibold))
              Text(item.status.localizedDisplayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(socialPreviewReadinessForeground(item.status))
            }
            Text(item.message)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialShareCopySection(_ items: [SEOSocialShareCopyItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("分享文案", systemImage: "square.and.arrow.up")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(item.kind.localizedDisplayName, systemImage: item.kind.systemImage)
              .font(.caption.weight(.semibold))
            Spacer()
            Button {
              copy(item.clipboardText, message: "已复制 \(item.kind.localizedDisplayName) 分享文案。")
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制分享文案")
            .accessibilityLabel("复制分享文案")
            .accessibilityValue(item.kind.localizedDisplayName)
          }

          Text(item.title)
            .font(.caption)
            .lineLimit(2)
          Text(item.body)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
          Text(item.urlText)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
          if !item.hashtagText.isEmpty {
            Text(item.hashtagText)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(8)
        .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialDebugLinkSection(_ links: [SEOSocialPreviewDebugLink]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("外部调试", systemImage: "safari")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(links.map(\.clipboardLine).joined(separator: "\n"), message: "已复制外部社交调试链接。")
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .disabled(links.isEmpty)
        .help("复制全部外部调试链接")
        .accessibilityLabel("复制全部外部调试链接")
      }

      ForEach(links) { link in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(link.title, systemImage: link.systemImage)
              .font(.caption.weight(.semibold))
            Spacer()
            Button {
              copy(link.urlText, message: "已复制 \(link.title) 链接。")
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制链接")
            .accessibilityLabel("复制外部调试链接")
            .accessibilityValue(link.title)

            Button {
              if let url = URL(string: link.urlText) {
                ExternalURLOpener.open(url)
              }
            } label: {
              Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("打开外部调试页")
            .accessibilityLabel("打开外部调试页")
            .accessibilityValue(link.title)
          }

          Text(link.purpose)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text(link.urlText)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
        .padding(8)
        .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(8)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialPreviewReadinessForeground(_ status: SEOSocialPreviewReadinessStatus) -> Color {
    switch status {
    case .ready:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .missing:
      return WorkbenchTheme.risk
    }
  }

  private func seoFindingRow(_ finding: SEOAuditFinding) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        SeverityBadge(severity: finding.severity)
        Text(finding.title)
          .font(.callout.weight(.medium))
      }
      Text(finding.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .padding(.vertical, 4)
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}

struct WorkspaceTaskChecksState {
  let issues: [PreflightIssue]
  let publicRisk: PublicRiskSummary

  var errorCount: Int {
    issues.filter { $0.severity == .error }.count
  }

  var warningCount: Int {
    issues.filter { $0.severity == .warning }.count
  }
}

struct WorkspaceTaskChecksActions {
  let rerunPreflight: () -> Void
  let focusIssue: (PreflightIssue) -> Void
}

struct WorkspaceTaskChecksSection: View {
  let state: WorkspaceTaskChecksState
  let actions: WorkspaceTaskChecksActions

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      InspectorSection("摘要") {
        InspectorStatRow(title: "错误", value: "\(state.errorCount)", systemImage: "xmark.octagon")
        InspectorStatRow(title: "警告", value: "\(state.warningCount)", systemImage: "exclamationmark.triangle")
        InspectorStatRow(title: "公开风险", value: state.publicRisk.statusTitle, systemImage: state.publicRisk.isClear ? "lock.open" : "lock.shield")

        Button {
          actions.rerunPreflight()
        } label: {
          Label("重新检查", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
      }

      InspectorSection("公开风险") {
        publicRiskSummaryBlock(state.publicRisk)
      }

      InspectorSection("问题队列") {
        if state.issues.isEmpty {
          Label("当前文章检查通过", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(state.issues) { issue in
            Button {
              actions.focusIssue(issue)
            } label: {
              IssueCompactRow(issue: issue)
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func publicRiskSummaryBlock(_ summary: PublicRiskSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: summary.isClear ? "lock.open" : "lock.shield")
          .foregroundStyle(summary.isClear ? Color.secondary : (summary.errorCount > 0 ? WorkbenchTheme.risk : WorkbenchTheme.warning))
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          Text(summary.statusTitle)
            .font(.callout.weight(.medium))
          Text(summary.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }

      if !summary.isClear {
        HStack(spacing: 10) {
          Label("\(summary.errorCount) 错误", systemImage: "xmark.octagon")
            .foregroundStyle(summary.errorCount > 0 ? .red : .secondary)
          Label("\(summary.warningCount) 警告", systemImage: "exclamationmark.triangle")
            .foregroundStyle(summary.warningCount > 0 ? .orange : .secondary)
        }
        .font(.caption2)

        ForEach(summary.issues.prefix(3)) { issue in
          Text("\(issue.severity.localizedDisplayName) · \(issue.title)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }
}

private struct IssueCompactRow: View {
  let issue: PreflightIssue
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      SeverityBadge(severity: issue.severity)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.caption.weight(.semibold))
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }
}

struct WorkspaceTaskImageState {
  let report: ImageWorkbenchReport?
  let siteSummary: ImageWorkbenchSiteSummary?
  let actionMessage: String?
}

struct WorkspaceTaskImageActions {
  let fillMissingMetadataForCurrentDraft: () -> Void
  let optimizeJPEGForCurrentDraft: () -> Void
  let openImageWorkbench: () -> Void
  let refreshReport: () -> Void
}

struct WorkspaceTaskImageSection: View {
  @Binding var draft: ArticleDraft
  let state: WorkspaceTaskImageState
  let actions: WorkspaceTaskImageActions

  var body: some View {
    let report = state.report
    let visibleIssues = report?.issues.filter { $0.title != "还没有图片" } ?? []
    let siteSummary = state.siteSummary

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("当前文章") {
        if let report {
          InspectorStatRow(title: "图片", value: "\(report.items.count)", systemImage: "photo")
          InspectorStatRow(title: "缺 alt", value: "\(report.missingAltTextCount)", systemImage: "text.quote")
          InspectorStatRow(title: "缺源图", value: "\(report.missingSourceCount)", systemImage: "xmark.octagon")
          InspectorStatRow(title: "可压缩 JPEG", value: "\(report.optimizableJPEGCount)", systemImage: "arrow.down.forward")
          Label(report.coverStatus.state.localizedDisplayName, systemImage: report.coverStatus.state.systemImage)
            .font(.caption)
            .foregroundStyle(report.coverStatus.state.color)
            .lineLimit(2)
        } else {
          ProgressView {
            Text("正在读取当前文章图片…")
          }
            .controlSize(.small)
        }
      }

      InspectorSection("图片元数据") {
        if draft.attachments.isEmpty {
          Text("当前文章还没有图片附件。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(draft.attachments) { attachment in
            ImageMetadataEditorRow(
              attachment: attachment,
              item: report?.items.first { $0.attachmentID == attachment.id },
              altText: attachmentStringBinding(for: attachment.id, keyPath: \.altText),
              caption: attachmentStringBinding(for: attachment.id, keyPath: \.caption)
            )
          }
        }
      }

      InspectorSection("图片问题") {
        if report == nil {
          ProgressView {
            Text("正在检查…")
          }
            .controlSize(.small)
        } else if visibleIssues.isEmpty {
          Label("图片检查通过", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(visibleIssues.prefix(5)) { issue in
            ImageIssueCompactRow(issue: issue)
          }
        }
      }

      InspectorSection("批处理") {
        if let siteSummary {
          InspectorStatRow(title: "站点图片", value: "\(siteSummary.imageCount)", systemImage: "photo.stack")
          InspectorStatRow(title: "站点缺 alt", value: "\(siteSummary.missingAltTextCount)", systemImage: "text.quote")
          InspectorStatRow(title: "可压缩 JPEG", value: "\(siteSummary.optimizableJPEGCount)", systemImage: "arrow.down.forward")
        } else {
          ProgressView {
            Text("正在统计站点图片…")
          }
            .controlSize(.small)
        }

        Button {
          actions.openImageWorkbench()
        } label: {
          Label("打开图片工作台", systemImage: "photo.on.rectangle")
        }
        .controlSize(.small)
      }

      actionMessage(state.actionMessage)
    }
  }

  private func attachmentStringBinding(
    for attachmentID: UUID,
    keyPath: WritableKeyPath<DraftAttachment, String>
  ) -> Binding<String> {
    Binding(
      get: {
        draft.attachments.first { $0.id == attachmentID }?[keyPath: keyPath] ?? ""
      },
      set: { value in
        guard let index = draft.attachments.firstIndex(where: { $0.id == attachmentID }) else {
          return
        }
        draft.attachments[index][keyPath: keyPath] = value
        actions.refreshReport()
      }
    )
  }
}

private struct ImageMetadataEditorRow: View {
  let attachment: DraftAttachment
  let item: ImageWorkbenchItem?
  @Binding var altText: String
  @Binding var caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(attachment.originalFilename)
          .font(.callout.weight(.medium))
          .lineLimit(1)

        if item?.isCover == true {
          Image(systemName: "star.fill")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: item?.fileExists == false ? "xmark.octagon" : "checkmark.circle")
          .foregroundStyle(item?.fileExists == false ? .red : .secondary)
      }

      Text(attachment.relativePublishPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)

      TextField("Alt", text: $altText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Alt 文本")
        .accessibilityValue(altText.isEmpty ? "未填写" : altText)

      TextField("Caption", text: $caption)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Caption")
        .accessibilityValue(caption.isEmpty ? "未填写" : caption)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片元数据 \(attachment.originalFilename)")
    .accessibilityValue(item?.fileExists == false ? "源图缺失" : "源图可用")
  }
}

private struct ImageIssueCompactRow: View {
  let issue: ImageWorkbenchIssue

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      SeverityBadge(severity: issue.severity)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.caption.weight(.semibold))
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }
}
