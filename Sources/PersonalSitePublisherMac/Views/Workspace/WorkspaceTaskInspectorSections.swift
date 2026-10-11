import AppKit
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

private struct WorkspaceTaskSEOPresentationKey: Hashable {
  let draftID: UUID
  let editorMetadataRevision: UInt64
  let updatedAt: Date
  let profile: SiteProfile
  let repositoryReportRevision: UUID
  let cachedSnapshotSignature: String?
  let cachedSnapshotDate: Date?
  let maintenanceSnapshotDate: Date?
  let actionMessage: String?
}

struct WorkspaceTaskSEOSection: View {
  let draft: ArticleDraft
  let store: WorkbenchStore
  @StateObject private var seoObservation: WorkbenchSEOInspectorFeatureFacade
  @State private var presentation: WorkbenchSEOInspectorPresentation?
  @State private var presentationErrorMessage: String?
  @State private var showsAllFindings = false
  @State private var showsSocialPreview = false
  @State private var showsSocialCards = false
  @State private var showsPlatformReadiness = false
  @State private var showsShareCopy = false
  @State private var showsExternalDebug = false
  @State private var showsRelatedArticles = false
  @State private var showsFrontMatter = false

  init(draft: ArticleDraft, store: WorkbenchStore) {
    self.draft = draft
    self.store = store
    _seoObservation = StateObject(
      wrappedValue: WorkbenchSEOInspectorFeatureFacade(store: store)
    )
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      let expandsScreenshotPreview =
        ScreenshotDemoDataService.isEnabledFromEnvironment
        && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .seoSocialPreview
      _showsSocialPreview = State(initialValue: expandsScreenshotPreview)
      _showsSocialCards = State(initialValue: expandsScreenshotPreview)
      _showsPlatformReadiness = State(initialValue: false)
    #endif
  }

  var body: some View {
    Group {
      if let presentation, presentation.draftID == draft.id {
        content(presentation)
      } else if let presentationErrorMessage {
        AccessibleStatusMessage(message: presentationErrorMessage, severity: .warning)
      } else {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在准备 SEO 检查…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .task(id: presentationKey) {
      await refreshPresentation()
    }
  }

  private func content(_ presentation: WorkbenchSEOInspectorPresentation) -> some View {
    let report = presentation.report
    let snapshot = presentation.socialPreviewSnapshot
    let cachePresentation = presentation.cachePresentation

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("SEO 摘要") {
        InspectorStatRow(
          title: "状态", value: report.statusTitle, systemImage: "chart.bar.doc.horizontal")
        InspectorStatRow(
          title: "标题",
          value: WorkspaceTaskInspectorPresentation.seoCharacterCountText(
            report.titleCharacterCount),
          systemImage: "doc.plaintext"
        )
        InspectorStatRow(
          title: "摘要",
          value: WorkspaceTaskInspectorPresentation.seoCharacterCountText(
            report.summaryCharacterCount),
          systemImage: "text.alignleft"
        )
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
          .foregroundStyle(
            cachePresentation.needsManualRefresh ? WorkbenchTheme.warning : Color.secondary)
      }

      if !prioritizesSocialPreviewForScreenshot {
        InspectorSection("重点建议") {
          Text(verbatim: "\(report.findings.count) 项")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          if report.findings.isEmpty {
            Label("未发现 SEO 问题", systemImage: "checkmark.seal")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.success)
          } else {
            ForEach(report.findings.prefix(3)) { finding in
              seoFindingRow(finding)
            }

            if report.findings.count > 3 {
              DisclosureGroup(
                "查看其余 \(report.findings.count - 3) 项",
                isExpanded: $showsAllFindings
              ) {
                VStack(alignment: .leading, spacing: 7) {
                  ForEach(report.findings.dropFirst(3)) { finding in
                    seoFindingRow(finding)
                  }
                }
                .padding(.top, WorkbenchSpacing.control)
              }
              .font(.caption)
            }
          }
        }
      }

      InspectorDisclosureSection(
        "社交预览",
        detail: socialPreviewDetail(snapshot),
        isExpanded: $showsSocialPreview
      ) {
        if let snapshot {
          let imagePresentation = WorkspaceTaskInspectorPresentation.socialImagePresentation(
            imagePath: snapshot.imagePath,
            imageDimensions: snapshot.imageDimensions
          )
          InspectorStatRow(
            title: "标题",
            value: WorkspaceTaskInspectorPresentation.seoCharacterCountText(
              snapshot.titleCharacterCount
            ),
            systemImage: "doc.plaintext"
          )
          InspectorStatRow(
            title: "描述",
            value: WorkspaceTaskInspectorPresentation.seoCharacterCountText(
              snapshot.descriptionCharacterCount
            ),
            systemImage: "text.alignleft"
          )
          VStack(alignment: .leading, spacing: 4) {
            InspectorStatRow(title: "图片", value: imagePresentation.value, systemImage: "photo")
              .foregroundStyle(
                imagePresentation.warning == nil ? Color.primary : WorkbenchTheme.warning)
            if let warning = imagePresentation.warning {
              Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(WorkbenchTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .help(warning)
                .accessibilityIdentifier("seo-social-image-size-warning")
            }
          }
          Text(snapshot.canonicalURLText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(snapshot.canonicalURLText, lineLimit: 2)

          InspectorDisclosureSection(
            "平台就绪度",
            detail: "\(snapshot.platformReadiness.count) 个平台",
            isExpanded: $showsPlatformReadiness
          ) {
            socialPreviewReadinessSection(snapshot)
          }

          InspectorDisclosureSection(
            "卡片预览",
            detail: "\(snapshot.cards.count) 张",
            isExpanded: $showsSocialCards
          ) {
            ForEach(snapshot.cards) { card in
              VStack(alignment: .leading, spacing: 8) {
                socialPreviewBudgetSummary(card)
                socialPreviewCard(card)
              }
            }
          }

          InspectorDisclosureSection(
            "分享文案",
            detail: "\(snapshot.socialShareCopyItems.count) 份",
            isExpanded: $showsShareCopy
          ) {
            socialShareCopySection(snapshot.socialShareCopyItems)
          }

          InspectorDisclosureSection(
            "外部调试",
            detail: "\(snapshot.externalDebugLinks.count) 个工具",
            isExpanded: $showsExternalDebug
          ) {
            socialDebugLinkSection(snapshot.externalDebugLinks)
          }
        } else {
          Text("还没有社交预览快照。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      relatedArticleSuggestionSection

      InspectorDisclosureSection(
        "文章头信息",
        detail: "Front Matter",
        isExpanded: $showsFrontMatter
      ) {
        Text(report.frontMatterPreview)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .lineLimit(16)
          .padding(WorkbenchSpacing.control)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }

      if let message = presentation.actionMessage {
        actionMessage(message)
      }
    }
  }

  private var presentationKey: WorkspaceTaskSEOPresentationKey {
    let cachedSnapshot = seoObservation.socialPreviewSnapshot(for: draft)
    return WorkspaceTaskSEOPresentationKey(
      draftID: draft.id,
      editorMetadataRevision: draft.editorMetadataRevision,
      updatedAt: draft.updatedAt,
      profile: store.profile(for: draft),
      repositoryReportRevision: store.repositoryReportRevision,
      cachedSnapshotSignature: cachedSnapshot?.signature,
      cachedSnapshotDate: cachedSnapshot?.generatedAt,
      maintenanceSnapshotDate: seoObservation.maintenanceSnapshotDate,
      actionMessage: seoObservation.actionMessage
    )
  }

  @MainActor
  private func refreshPresentation() async {
    let expectedKey = presentationKey
    presentationErrorMessage = nil
    do {
      try await Task.sleep(for: .milliseconds(180))
      try Task.checkCancellation()
      let candidate = try await store.seoInspectorPresentation(for: draft)
      guard !Task.isCancelled,
        presentationKey == expectedKey,
        candidate.draftID == draft.id
      else { return }
      presentation = candidate
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, presentationKey == expectedKey else { return }
      presentation = nil
      presentationErrorMessage = error.localizedDescription
    }
  }

  private var prioritizesSocialPreviewForScreenshot: Bool {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      ScreenshotDemoDataService.isEnabledFromEnvironment
        && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .seoSocialPreview
    #else
      false
    #endif
  }

  @ViewBuilder
  private var relatedArticleSuggestionSection: some View {
    let suggestions = presentation?.relatedArticleSuggestions ?? []
    if !suggestions.isEmpty {
      InspectorDisclosureSection(
        "关联文章",
        detail: "\(suggestions.count) 项建议",
        isExpanded: $showsRelatedArticles
      ) {
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
                    .workbenchTruncatedIdentity(suggestion.targetTitle)
                  Text(suggestion.targetPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .workbenchTruncatedIdentity(suggestion.targetPath)
                }
                Spacer(minLength: 0)
              }

              Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

              if !suggestion.sharedLabels.isEmpty {
                Text(suggestion.sharedLabels.joined(separator: "、"))
                  .font(.caption)
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
            .padding(WorkbenchSpacing.control)
            .background(
              WorkbenchBackgroundStyle.card,
              in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
          }
        }
      }
    }
  }

  private func socialPreviewDetail(_ snapshot: SEOSocialPreviewSnapshot?) -> String {
    guard let snapshot else { return "未生成" }
    return "\(snapshot.cards.count) 张卡片"
  }

  private func socialPreviewBudgetSummary(_ card: SEOSocialPreviewCard) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(card.kind.localizedDisplayName, systemImage: card.kind.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        socialPreviewBudgetLabel(
          fieldName: "标题",
          countText: card.titleBudgetText,
          limit: card.titleCharacterLimit,
          isWithinBudget: card.isTitleWithinBudget
        )
        socialPreviewBudgetLabel(
          fieldName: "描述",
          countText: card.descriptionBudgetText,
          limit: card.descriptionCharacterLimit,
          isWithinBudget: card.isDescriptionWithinBudget
        )
      }

      if let imageAspectRatio = card.imageAspectRatio {
        Text("图片建议比例：\(imageAspectRatio)。\(card.imageGuidance)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(card.kind.localizedDisplayName) 内容预算")
    .accessibilityValue(
      "标题 \(card.titleBudgetText) 字符，建议不超过 \(card.titleCharacterLimit) 字符。描述 \(card.descriptionBudgetText) 字符，建议不超过 \(card.descriptionCharacterLimit) 字符。"
    )
  }

  private func socialPreviewBudgetLabel(
    fieldName: String,
    countText: String,
    limit: Int,
    isWithinBudget: Bool
  ) -> some View {
    let localizedFieldName = String(localized: String.LocalizationValue(fieldName))
    return Label {
      Text("\(localizedFieldName) \(countText) 字符")
    } icon: {
      Image(systemName: isWithinBudget ? "checkmark.circle" : "exclamationmark.triangle")
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(isWithinBudget ? Color.secondary : WorkbenchTheme.warning)
    .help("\(localizedFieldName)建议不超过 \(limit) 字符")
    .accessibilityLabel("\(localizedFieldName)字符数")
    .accessibilityValue(
      "\(countText) 字符，建议不超过 \(limit) 字符"
    )
  }

  @ViewBuilder
  private func socialPreviewCard(_ card: SEOSocialPreviewCard) -> some View {
    switch card.kind {
    case .search:
      searchResultPreview(card)
    case .openGraph:
      openGraphPreview(card)
    case .twitter:
      xCardPreview(card)
    }
  }

  private func searchResultPreview(_ card: SEOSocialPreviewCard) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Image(systemName: "globe")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(card.siteName)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(card.urlText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Text(card.title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .workbenchTruncatedIdentity(card.title, lineLimit: 2)
      Text(card.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .strokeBorder(.quaternary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("搜索结果预览")
    .accessibilityValue(socialPreviewAccessibilityValue(card))
  }

  private func openGraphPreview(_ card: SEOSocialPreviewCard) -> some View {
    let imageDescription = socialPreviewImageAccessibilityText(card)
    return VStack(alignment: .leading, spacing: 0) {
      socialPreviewImage(card, placeholder: "Open Graph 图片")
      VStack(alignment: .leading, spacing: 5) {
        Text("\(card.siteName) · \(card.urlText)")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(card.title)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(card.title, lineLimit: 2)
        Text(card.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      .padding(WorkbenchSpacing.card)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .strokeBorder(.quaternary)
    }
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Open Graph 链接卡片预览")
    .accessibilityValue(
      socialPreviewAccessibilityValue(card, imageDescription: imageDescription)
    )
  }

  private func xCardPreview(_ card: SEOSocialPreviewCard) -> some View {
    let imageDescription = socialPreviewImageAccessibilityText(card)
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("𝕏")
          .font(.title3.weight(.bold))
        Text(card.siteName)
          .font(.caption.weight(.semibold))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkbenchSpacing.card)
      .padding(.top, WorkbenchSpacing.control)

      socialPreviewImage(card, placeholder: "X 卡片图片")
        .padding(.top, WorkbenchSpacing.control)

      VStack(alignment: .leading, spacing: 4) {
        Text(card.urlText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(card.title)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(card.title, lineLimit: 2)
        Text(card.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(WorkbenchSpacing.card)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .strokeBorder(.quaternary)
    }
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("X 链接卡片预览")
    .accessibilityValue(
      socialPreviewAccessibilityValue(card, imageDescription: imageDescription)
    )
  }

  private func socialPreviewAccessibilityValue(
    _ card: SEOSocialPreviewCard,
    imageDescription: String? = nil
  ) -> String {
    var parts = [
      "站点 \(card.siteName)",
      "地址 \(card.urlText)",
      "标题 \(card.title)",
      "描述 \(card.description)",
    ]
    if let imageDescription { parts.append(imageDescription) }
    return parts.joined(separator: "，")
  }

  @ViewBuilder
  private func socialPreviewImage(_ card: SEOSocialPreviewCard, placeholder: String) -> some View {
    if let imagePath = socialPreviewImageFilePath(card),
      let image = NSImage(contentsOfFile: imagePath)
    {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .clipped()
        .accessibilityHidden(true)
    } else {
      VStack(spacing: 6) {
        Image(systemName: "photo")
          .font(.title3)
        Text(placeholder)
          .font(.caption)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 132)
      .background(.quaternary)
      .accessibilityHidden(true)
    }
  }

  private func socialPreviewImageAccessibilityText(_ card: SEOSocialPreviewCard) -> String {
    guard let imagePath = socialPreviewImageFilePath(card) else {
      return "未设置社交图片"
    }
    guard NSImage(contentsOfFile: imagePath) != nil else {
      return "社交图片不可用，显示占位"
    }
    if let imageAltText = card.imageAltText?.nilIfEmpty {
      return "图片：\(imageAltText)"
    }
    return "已设置社交图片"
  }

  private func socialPreviewImageFilePath(_ card: SEOSocialPreviewCard) -> String? {
    guard let imagePath = card.imagePath?.nilIfEmpty else { return nil }
    // Only render a source image already attached to this draft. Metadata may
    // contain arbitrary paths, which must not make the inspector read local files.
    return draft.attachments.first(where: { $0.relativePublishPath == imagePath })?.sourceFilePath
  }

  private func socialPreviewReadinessSection(_ snapshot: SEOSocialPreviewSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          copy(
            snapshot.socialShareChecklistMarkdown,
            message: String(localized: "已复制 SEO / Social 检查清单。")
          )
        } label: {
          Label("复制清单", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制 SEO / Social 检查清单")
        .accessibilityLabel("复制 SEO Social 检查清单")

        Button {
          copy(snapshot.metaTags.htmlBlock, message: String(localized: "已复制社交预览 Meta HTML。"))
        } label: {
          Label("复制 Meta", systemImage: "curlybraces")
        }
        .buttonStyle(.borderless)
        .disabled(snapshot.metaTags.isEmpty)
        .help("复制 Meta HTML")
        .accessibilityLabel("复制社交预览 Meta HTML")

        Spacer(minLength: 0)
      }
      .controlSize(.small)

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
                .font(.caption.weight(.medium))
                .foregroundStyle(socialPreviewReadinessForeground(item.status))
            }
            Text(item.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.localizedDisplayName)：\(item.status.localizedDisplayName)")
        .accessibilityValue(item.message)
      }
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialShareCopySection(_ items: [SEOSocialShareCopyItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(item.kind.localizedDisplayName, systemImage: item.kind.systemImage)
              .font(.caption.weight(.semibold))
            Spacer()
            Button {
              copy(
                item.clipboardText,
                message: String(
                  format: String(localized: "已复制 %@ 分享文案。"),
                  item.kind.localizedDisplayName
                )
              )
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
            .workbenchTruncatedIdentity(item.title, lineLimit: 2)
          Text(item.body)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
          Text(item.urlText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(item.urlText)
          if !item.hashtagText.isEmpty {
            Text(item.hashtagText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(WorkbenchSpacing.control)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialDebugLinkSection(_ links: [SEOSocialPreviewDebugLink]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Spacer(minLength: 0)
        Button {
          copy(
            links.map(\.clipboardLine).joined(separator: "\n"),
            message: String(localized: "已复制外部社交调试链接。")
          )
        } label: {
          Label("复制全部", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .disabled(links.isEmpty)
        .help("复制全部外部调试链接")
        .accessibilityLabel("复制全部外部调试链接")
      }
      .controlSize(.small)

      ForEach(links) { link in
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(link.title, systemImage: link.systemImage)
              .font(.caption.weight(.semibold))
            Spacer()
            Button {
              copy(
                link.urlText,
                message: String(
                  format: String(localized: "已复制 %@ 链接。"),
                  link.title
                )
              )
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text(link.urlText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(link.urlText)
        }
        .padding(WorkbenchSpacing.control)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(WorkbenchSpacing.control)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialPreviewReadinessForeground(_ status: SEOSocialPreviewReadinessStatus) -> Color
  {
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
    .padding(.vertical, WorkbenchSpacing.tight)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(finding.severity.localizedDisplayName)：\(finding.title)")
    .accessibilityValue(finding.message)
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
  }
}

struct WorkspaceTaskChecksState {
  let issues: [PreflightIssue]
  let publicRisk: PublicRiskSummary
  let deploymentStatus: DeploymentStatusSnapshot?
  let deploymentSourceContext: DeploymentSourceContext?

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
        InspectorStatRow(
          title: "警告", value: "\(state.warningCount)", systemImage: "exclamationmark.triangle")
        InspectorStatRow(
          title: "公开风险", value: state.publicRisk.statusTitle,
          systemImage: state.publicRisk.isClear ? "lock.open" : "lock.shield")

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

      if let deploymentStatus = state.deploymentStatus,
        deploymentStatus.level == .failed
          || deploymentStatus.level == .running
          || deploymentStatus.signals.contains(where: { !$0.logExcerpt.isEmpty })
      {
        WorkspaceDeploymentLogInspectorSection(
          snapshot: deploymentStatus, sourceContext: state.deploymentSourceContext)
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
          .foregroundStyle(
            summary.isClear
              ? Color.secondary
              : (summary.errorCount > 0 ? WorkbenchTheme.risk : WorkbenchTheme.warning)
          )
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
            .foregroundStyle(summary.errorCount > 0 ? WorkbenchTheme.risk : Color.secondary)
          Label("\(summary.warningCount) 警告", systemImage: "exclamationmark.triangle")
            .foregroundStyle(summary.warningCount > 0 ? WorkbenchTheme.warning : Color.secondary)
        }
        .font(.caption)

        ForEach(summary.issues.prefix(3)) { issue in
          let issueTitle = "\(issue.severity.localizedDisplayName) · \(issue.title)"
          Text(issueTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(issueTitle)
        }
      }
    }
    .padding(WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
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
      Spacer(minLength: 8)
      Label("定位到\(issue.contentHealthFocusTargetTitle)", systemImage: "arrow.right.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }
  }
}
