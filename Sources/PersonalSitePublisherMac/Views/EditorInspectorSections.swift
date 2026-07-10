import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct EditorFrontMatterSection: View {
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Front Matter")
        .font(.headline)

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

      DatePicker("Date", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
        .accessibilityLabel("文章日期")
        .accessibilityValue(draft.date.formatted(date: .abbreviated, time: .shortened))

      Picker("Visibility", selection: $draft.visibility) {
        ForEach(ArticleVisibility.allCases) { visibility in
          Label(visibility.displayName, systemImage: visibility.systemImage)
            .tag(visibility)
        }
      }
      .accessibilityLabel("文章可见性")
      .accessibilityValue(draft.visibility.displayName)

      Toggle("Draft", isOn: $draft.draft)
        .accessibilityLabel("草稿状态")
        .accessibilityValue(draft.draft ? "草稿" : "非草稿")
      TextField("Tags", text: tagsBinding)
        .accessibilityLabel("文章标签")
        .accessibilityValue(draft.tags.isEmpty ? "未填写" : draft.tags.joined(separator: "，"))
      TextField("Categories", text: categoriesBinding)
        .accessibilityLabel("文章分类")
        .accessibilityValue(draft.categories.isEmpty ? "未填写" : draft.categories.joined(separator: "，"))

      reuseSourceTraceSection
    }
  }

  @ViewBuilder
  private var reuseSourceTraceSection: some View {
    if let snapshot = draft.reusedFromSourceSnapshot {
      let diffs = store.generalDraftSourceFieldDiffs(for: draft)
      let capturedText = snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)
      let sourcePathText = snapshot.repositoryPath ?? "未绑定路径"

      VStack(alignment: .leading, spacing: 8) {
        Text("复用来源追溯")
          .font(.headline)

        Text("来源站点：\(snapshot.sourceProfileName)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("来源草稿：\(snapshot.title)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text("来源路径：\(sourcePathText)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text("来源快照：\(capturedText)")
          .font(.caption)
          .foregroundStyle(.secondary)

        if diffs.isEmpty {
          Text("当前草稿与来源快照在主要字段上无差异（标题、Slug、摘要、标签、分类、发布状态、正文长度）。")
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
          Text("字段对比（来源）")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(diffs, id: \.self) { item in
            Label(item, systemImage: "line.3.horizontal")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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

  private func parseList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

struct EditorSEOSection: View {
  let draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.seoReport(for: draft)

    return VStack(alignment: .leading, spacing: 10) {
      Text("SEO")
        .font(.headline)

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        MetricTile(title: "状态", value: report.statusTitle, systemImage: "chart.bar.doc.horizontal")
        MetricTile(title: "标题", value: "\(report.titleCharacterCount) 字", systemImage: "textformat.size")
        MetricTile(title: "摘要", value: "\(report.summaryCharacterCount) 字", systemImage: "text.alignleft")
        MetricTile(title: "H1", value: "\(report.h1Count)", systemImage: "number")
      }

      ForEach(report.findings.prefix(7)) { finding in
        seoFindingRow(finding)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Front Matter 预览")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(report.frontMatterPreview)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(14)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
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
}

struct EditorSocialPreviewSection: View {
  let draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let snapshot = store.seoSocialPreviewSnapshot(for: draft)
    let cachePresentation = store.seoSocialPreviewCachePresentation(for: draft)

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("社交预览")
          .font(.headline)
        Spacer()
        if cachePresentation.needsManualRefresh {
          Label(cachePresentation.state.displayName, systemImage: cachePresentation.state.systemImage)
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Button {
          store.refreshSEOSocialPreview(for: draft)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("刷新社交预览快照")
        .accessibilityLabel("刷新社交预览快照")
      }

      Label(cachePresentation.message, systemImage: cachePresentation.state.systemImage)
        .font(.caption)
        .foregroundStyle(cachePresentation.needsManualRefresh ? .orange : .secondary)

      if let snapshot {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          MetricTile(title: "标题", value: "\(snapshot.titleCharacterCount) 字", systemImage: "textformat.size")
          MetricTile(title: "描述", value: "\(snapshot.descriptionCharacterCount) 字", systemImage: "text.alignleft")
          MetricTile(title: "图片", value: snapshot.imageDimensions?.displayName ?? (snapshot.imagePath == nil ? "未设置" : "已设置"), systemImage: "photo")
          MetricTile(title: "快照", value: snapshot.generatedAt.workbenchShortText, systemImage: "clock")
        }

        Text(snapshot.canonicalURLText)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)

        Label(snapshot.renderingMode.message, systemImage: "camera.metering.matrix")
          .font(.caption)
          .foregroundStyle(.secondary)

        socialPreviewReadiness(snapshot.platformReadiness, checklist: snapshot.socialShareChecklistMarkdown)
        structuredDataSection(snapshot.structuredData)
        sitemapPreviewSection(store.seoSitemapPreview(for: draft))
        socialShareCopySection(snapshot.socialShareCopyItems)
        socialDebugLinkSection(snapshot.externalDebugLinks)
        socialMobilePreviewSection(snapshot.cards)

        ForEach(snapshot.cards) { card in
          socialPreviewCard(card)
        }

        if !snapshot.metaTags.isEmpty {
          socialPreviewMetaTags(snapshot.metaTags)
        }

        ForEach(snapshot.findings.prefix(3)) { finding in
          VStack(alignment: .leading, spacing: 4) {
            SeverityBadge(severity: finding.severity)
            Text(finding.title)
              .font(.callout.weight(.medium))
            Text(finding.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          .padding(.vertical, 4)
        }

        relatedArticleSuggestionSection()
      } else {
        EmptyStateView(
          title: "还没有社交预览",
          message: "刷新后生成搜索、Open Graph 和 Twitter/X 卡片快照。",
          systemImage: "rectangle.on.rectangle"
        )
        .frame(height: 150)
      }

      HStack {
        Button {
          store.refreshSEOSocialPreview(for: draft)
        } label: {
          Label(cachePresentation.manualRefreshTitle, systemImage: "arrow.clockwise")
        }

        Button {
          if let package = store.seoSocialPublishPackageMarkdown(for: draft) {
            copy(package)
            store.setSEOSocialPreviewMessage("已复制 SEO / Social 发布包。")
          }
        } label: {
          Label("复制发布包", systemImage: "doc.on.doc")
        }
        .disabled(snapshot == nil)
      }
      .controlSize(.small)

      if let message = store.seoSocialPreviewMessage, snapshot != nil {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func socialPreviewCard(_ card: SEOSocialPreviewCard) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(card.kind.displayName, systemImage: card.kind.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        socialPreviewBudgetBadge(
          title: "标题",
          value: card.titleBudgetText,
          isWithinBudget: card.isTitleWithinBudget
        )
        socialPreviewBudgetBadge(
          title: "描述",
          value: card.descriptionBudgetText,
          isWithinBudget: card.isDescriptionWithinBudget
        )
        if let imageAspectRatio = card.imageAspectRatio {
          Label(imageAspectRatio, systemImage: "aspectratio")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if let imageDimensions = card.imageDimensions {
          Label(imageDimensions.displayName, systemImage: "ruler")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if let imagePath = card.imagePath {
        ZStack(alignment: .bottomLeading) {
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(WorkbenchBackgroundStyle.control)
            .frame(height: 82)
          Label(imagePath, systemImage: "photo")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(8)
        }
      }

      Text(card.imageGuidance)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(2)

      Text(card.urlText)
        .font(.caption2)
        .foregroundStyle(card.kind == .search ? .green : .secondary)
        .lineLimit(1)

      Text(card.title)
        .font(card.kind == .search ? .callout.weight(.semibold) : .caption.weight(.semibold))
        .foregroundStyle(card.kind == .search ? .blue : .primary)
        .lineLimit(2)

      Text(card.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      if let imageAltText = card.imageAltText {
        Text(imageAltText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func structuredDataSection(_ structuredData: SEOStructuredDataPreview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("结构化数据", systemImage: "curlybraces.square")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(structuredData.jsonLD)
          store.setSEOSocialPreviewMessage("已复制 JSON-LD。")
        } label: {
          Label("复制 JSON-LD", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .accessibilityLabel("复制 JSON-LD")
      }

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: structuredData.status.systemImage)
          .foregroundStyle(socialPreviewReadinessForeground(structuredData.status))
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 3) {
          Text(structuredData.title)
            .font(.caption.weight(.semibold))
          Text(structuredData.message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Text(structuredData.jsonLD)
        .font(.caption2.monospaced())
        .textSelection(.enabled)
        .lineLimit(8)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func sitemapPreviewSection(_ sitemap: SEOSitemapPreview) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("sitemap.xml", systemImage: "map")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(sitemap.xml)
          store.setSEOSocialPreviewMessage("已复制 sitemap.xml 预览。")
        } label: {
          Label("复制 XML", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .accessibilityLabel("复制 sitemap XML")
      }

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: sitemap.status.systemImage)
          .foregroundStyle(socialPreviewReadinessForeground(sitemap.status))
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 3) {
          Text(sitemap.title)
            .font(.caption.weight(.semibold))
          Text(sitemap.message)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      if let sitemapURLText = sitemap.sitemapURLText {
        Text(sitemapURLText)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)
      }

      ForEach(Array(sitemap.entries.prefix(5))) { entry in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: entry.isSelectedDraft ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(entry.isSelectedDraft ? Color.green : Color.secondary)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
              .font(.caption2.weight(.medium))
              .lineLimit(1)
            Text(entry.loc)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func socialMobilePreviewSection(_ cards: [SEOSocialPreviewCard]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("移动端预览模拟", systemImage: "iphone")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(cards.filter { $0.kind != .search }) { card in
        mobileSocialCard(card)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func mobileSocialCard(_ card: SEOSocialPreviewCard) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .bottomLeading) {
        Rectangle()
          .fill(WorkbenchBackgroundStyle.control)
          .aspectRatio(1.91, contentMode: .fit)
        Label(card.imagePath ?? "无预览图", systemImage: card.imagePath == nil ? "photo.badge.exclamationmark" : "photo")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(8)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(card.siteName)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        Text(card.title)
          .font(.caption.weight(.semibold))
          .lineLimit(2)
        Text(card.description)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(8)
    }
    .frame(maxWidth: 320, alignment: .leading)
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(.quaternary, lineWidth: 1)
    }
  }

  @ViewBuilder
  private func relatedArticleSuggestionSection() -> some View {
    let suggestions = store.relatedArticleSuggestions(for: draft, limit: 3)
    if !suggestions.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("关联文章建议", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        ForEach(suggestions) { suggestion in
          VStack(alignment: .leading, spacing: 5) {
            Text(suggestion.targetTitle)
              .font(.caption.weight(.medium))
              .lineLimit(1)
            Text(suggestion.reason)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            Text(suggestion.targetPath)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(1)

            HStack {
              Button {
                store.selectDraft(suggestion.targetDraftID)
              } label: {
                Label("打开目标", systemImage: "arrow.forward.circle")
              }
            }
            .controlSize(.small)
          }

          if suggestion.id != suggestions.last?.id {
            Divider()
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  private func socialPreviewBudgetBadge(
    title: String,
    value: String,
    isWithinBudget: Bool
  ) -> some View {
    Label("\(title) \(value)", systemImage: isWithinBudget ? "checkmark.circle" : "exclamationmark.triangle")
      .font(.caption2)
      .foregroundStyle(isWithinBudget ? Color.secondary : Color.orange)
  }

  private func socialShareCopySection(_ items: [SEOSocialShareCopyItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("分享文案", systemImage: "square.and.arrow.up")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline) {
            Label(item.kind.displayName, systemImage: item.kind.systemImage)
              .font(.caption.weight(.semibold))
            Spacer()
            Button {
              copy(item.clipboardText)
              store.setSEOSocialPreviewMessage("已复制 \(item.kind.displayName) 分享文案。")
            } label: {
              Label("复制", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
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
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func socialDebugLinkSection(_ links: [SEOSocialPreviewDebugLink]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("外部调试", systemImage: "safari")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(links.map(\.clipboardLine).joined(separator: "\n"))
          store.setSEOSocialPreviewMessage("已复制外部社交调试链接。")
        } label: {
          Label("复制全部", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .disabled(links.isEmpty)
      }

      ForEach(links) { link in
        HStack(alignment: .top, spacing: 8) {
          Label(link.title, systemImage: link.systemImage)
            .font(.caption.weight(.semibold))
          Spacer()
          Button {
            copy(link.urlText)
            store.setSEOSocialPreviewMessage("已复制 \(link.title) 链接。")
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
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func socialPreviewReadiness(
    _ items: [SEOSocialPreviewPlatformReadiness],
    checklist: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("平台就绪度", systemImage: "checklist.checked")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(checklist)
          store.setSEOSocialPreviewMessage("已复制 SEO / Social 检查清单。")
        } label: {
          Label("复制清单", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .accessibilityLabel("复制 SEO Social 检查清单")
      }

      ForEach(items) { item in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: item.status.systemImage)
            .foregroundStyle(socialPreviewReadinessForeground(item.status))
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              Text(item.kind.displayName)
                .font(.caption.weight(.semibold))
              Text(item.status.displayName)
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
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func socialPreviewReadinessForeground(_ status: SEOSocialPreviewReadinessStatus) -> Color {
    switch status {
    case .ready:
      return .green
    case .warning:
      return .orange
    case .missing:
      return .red
    }
  }

  private func socialPreviewMetaTags(_ tags: [SEOSocialPreviewMetaTag]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("Meta 字段", systemImage: "curlybraces")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(tags.htmlBlock)
          store.setSEOSocialPreviewMessage("已复制社交预览 Meta HTML。")
        } label: {
          Label("复制 HTML", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .disabled(tags.isEmpty)
      }

      ForEach(SEOSocialPreviewCardKind.allCases) { kind in
        let scopedTags = tags.filter { $0.scope == kind }
        if !scopedTags.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Label(kind.displayName, systemImage: kind.systemImage)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
            ForEach(scopedTags.prefix(5)) { tag in
              socialPreviewMetaTagRow(tag)
            }
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func socialPreviewMetaTagRow(_ tag: SEOSocialPreviewMetaTag) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(tag.property)
        .font(.caption.monospaced())
        .foregroundStyle(tag.isRequired ? .primary : .secondary)
        .frame(width: 112, alignment: .leading)
      Text(tag.content)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  private func copy(_ text: String) {
    ClipboardWriter.copy(text, successMessage: "已复制到剪贴板。") { _ in }
  }
}

struct EditorPathSection: View {
  let draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("发布路径")
        .font(.headline)
      Text(store.profile(for: draft).markdownPath(for: draft))
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .lineLimit(3)

      if let report = store.repositoryReport(for: draft) {
        Label(report.statusTitle, systemImage: "externaldrive")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Label("\(store.publishingPackage(for: draft).files.count) 个发布文件", systemImage: "shippingbox")
        .font(.caption)
        .foregroundStyle(.secondary)

      Label("\(store.localPublishPreview(for: draft).changedFileDiffs.count) 个待写入变化", systemImage: "arrow.left.arrow.right")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let plan = store.localSitePreviewPlan(for: draft) {
        Label(plan.previewURL.absoluteString, systemImage: "safari")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Label(store.remoteReviewDraft(for: draft).branchName, systemImage: "arrow.triangle.branch")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

struct EditorImageSection: View {
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.imageWorkbenchReport(for: draft)
    let visibleIssues = report.issues.filter { $0.title != "还没有图片" }

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("图片")
          .font(.headline)
        Spacer()
        Button {
          store.focusDraft(draft.id, section: .images)
        } label: {
          Image(systemName: "photo.on.rectangle.angled")
        }
        .buttonStyle(.borderless)
        .help("打开图片工作台")
        .accessibilityLabel("打开图片工作台")
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        MetricTile(title: "图片", value: "\(report.items.count)", systemImage: "photo")
        MetricTile(title: "缺 alt", value: "\(report.missingAltTextCount)", systemImage: "text.quote")
      }

      Label(report.coverStatus.state.displayName, systemImage: report.coverStatus.state.systemImage)
        .font(.caption)
        .foregroundStyle(report.coverStatus.state.color)

      if let field = report.coverStatus.frontMatterFieldPath {
        Text(field)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(2)
      }

      if draft.attachments.isEmpty {
        Text("当前文章还没有图片附件。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(draft.attachments.prefix(3))) { attachment in
          imageAttachmentRow(
            attachment,
            item: report.items.first { $0.attachmentID == attachment.id }
          )
        }

        if draft.attachments.count > 3 {
          Button {
            store.focusDraft(draft.id, section: .images)
          } label: {
            Label("还有 \(draft.attachments.count - 3) 张，去图片工作台", systemImage: "arrow.right.circle")
          }
          .buttonStyle(.link)
        }
      }

      ForEach(visibleIssues.prefix(3)) { issue in
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
        store.refreshImageWorkbenchReport()
      }
    )
  }

  private func imageAttachmentRow(_ attachment: DraftAttachment, item: ImageWorkbenchItem?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(attachment.originalFilename)
          .font(.callout.weight(.medium))
          .lineLimit(1)

        if item?.isCover == true {
          Label("封面", systemImage: "star.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: item?.fileExists == false ? "xmark.octagon" : "checkmark.circle")
          .foregroundStyle(item?.fileExists == false ? .red : .secondary)
      }

      Text(attachment.relativePublishPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)

      TextField("Alt", text: attachmentStringBinding(for: attachment.id, keyPath: \.altText))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Alt 文本")
        .accessibilityValue(attachment.altText.isEmpty ? "未填写" : attachment.altText)

      TextField("Caption", text: attachmentStringBinding(for: attachment.id, keyPath: \.caption))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Caption")
        .accessibilityValue(attachment.caption.isEmpty ? "未填写" : attachment.caption)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片元数据 \(attachment.originalFilename)")
    .accessibilityValue(item?.fileExists == false ? "源图缺失" : "源图可用")
  }
}
