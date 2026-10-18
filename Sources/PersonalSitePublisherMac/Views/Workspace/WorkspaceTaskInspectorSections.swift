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

extension WorkspaceTaskSEOPreferenceControls {
  init(draft: ArticleDraft, presentation: WorkbenchSEOInspectorPresentation, store: WorkbenchStore)
  {
    let profileID = store.profile(for: draft).id
    self.init(
      themeProvidesTitleH1: Binding(
        get: { store.profile(for: draft).themeProvidesTitleH1 },
        set: { store.setSEOThemeProvidesTitleH1($0, forProfileID: profileID) }),
      duplicateTitleWarning: Binding(
        get: { store.profile(for: draft).resolvedWarnsWhenBodyH1DuplicatesTitle },
        set: { store.setH1DuplicateWarning($0, forProfileID: profileID) }),
      defaultSocialImagePath: Binding(
        get: { store.profile(for: draft).defaultSocialImagePath ?? "" },
        set: { store.setSEODefaultSocialImagePath($0, forProfileID: profileID) }),
      defaultSocialImageAltText: Binding(
        get: { store.profile(for: draft).defaultSocialImageAltText ?? "" },
        set: { store.setSEODefaultSocialImageAltText($0, forProfileID: profileID) }),
      noIndividualImage: Binding(
        get: {
          store.profile(for: draft).seoArticleSocialImageIntent(for: draft.id)
            == .noIndividualImage
        },
        set: {
          store.setSEOArticleSocialImageIntent(
            $0 ? .noIndividualImage : nil, draftID: draft.id, profileID: profileID)
        }),
      resolutionName: presentation.themeTitleH1Resolution.workbenchLocalizedDisplayName,
      resolutionSourceName: presentation.themeTitleH1Resolution.source.workbenchLocalizedDisplayName
    )
  }
}
struct WorkspaceTaskSEOSection: View {
  let draft: ArticleDraft
  let store: WorkbenchStore
  @Environment(\.showPublishChecks) private var showPublishChecks
  @StateObject private var seoObservation: WorkbenchSEOInspectorFeatureFacade
  @State private var presentation: WorkbenchSEOInspectorPresentation?
  @State private var presentationErrorMessage: String?
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
    _seoObservation = StateObject(wrappedValue: WorkbenchSEOInspectorFeatureFacade(store: store))
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
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
        }
      }
    }
    .task(id: presentationKey) { await refreshPresentation() }
  }
  private func content(_ presentation: WorkbenchSEOInspectorPresentation) -> some View {
    let report = presentation.report
    let snapshot = presentation.socialPreviewSnapshot
    let cachePresentation = presentation.cachePresentation
    let countText = WorkspaceTaskInspectorPresentation.seoCharacterCountText

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("SEO 摘要") {
        InspectorStatRow(
          title: "状态", value: report.statusTitle, systemImage: "chart.bar.doc.horizontal")
        InspectorStatRow(
          title: "标题", value: countText(report.titleCharacterCount), systemImage: "doc.plaintext")
        InspectorStatRow(
          title: "摘要", value: countText(report.summaryCharacterCount), systemImage: "text.alignleft"
        )
        InspectorStatRow(title: "H1", value: "\(report.h1Count)", systemImage: "number")
        WorkspaceTaskSEOPreferenceControls(draft: draft, presentation: presentation, store: store)
        HStack {
          Button {
            store.refreshSEOSocialPreview(for: draft)
          } label: {
            Label(cachePresentation.manualRefreshTitle, systemImage: "arrow.clockwise")
          }
        }
        .controlSize(.small)
        Label(cachePresentation.message, systemImage: cachePresentation.state.systemImage)
          .font(.workbenchMetadata)
          .foregroundStyle(
            cachePresentation.needsManualRefresh ? WorkbenchTheme.warning : Color.secondary)
      }

      if !prioritizesSocialPreviewForScreenshot {
        InspectorSection("SEO 建议") {
          if report.findings.isEmpty {
            Label("未发现 SEO 问题", systemImage: "checkmark.seal")
              .font(.workbenchMetadata)
              .foregroundStyle(WorkbenchTheme.success)
          } else {
            PublishChecksLink(
              summary: String(localized: "\(report.findings.count) 项 SEO 建议"),
              action: showPublishChecks
            )
          }
        }
      }

      InspectorDisclosureSection(
        "社交预览",
        detail: socialPreviewDetail(snapshot),
        isExpanded: $showsSocialPreview
      ) {
        if let snapshot {
          InspectorStatRow(
            title: "标题", value: countText(snapshot.titleCharacterCount),
            systemImage: "doc.plaintext")
          InspectorStatRow(
            title: "描述", value: countText(snapshot.descriptionCharacterCount),
            systemImage: "text.alignleft")
          let imagePresentation = WorkspaceTaskInspectorPresentation.socialImagePresentation(
            imagePath: snapshot.imagePath,
            imageDimensions: snapshot.imageDimensions
          )
          WorkspaceTaskSEOSocialImageSummary(
            value: imagePresentation.value,
            warning: imagePresentation.warning,
            sourceName: snapshot.imageSource.workbenchLocalizedDisplayName
          )
          Text(snapshot.canonicalURLText)
            .font(.workbenchMetadata.monospaced())
            .foregroundStyle(.workbenchSecondary)
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
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
        }
      }

      relatedArticleSuggestionSection

      InspectorDisclosureSection(
        "文章头信息",
        detail: "Front Matter",
        isExpanded: $showsFrontMatter
      ) {
        Text(report.frontMatterPreview)
          .font(.workbenchMetadata.monospaced())
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
                  .foregroundStyle(.workbenchSecondary)
                  .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                  Text(suggestion.targetTitle)
                    .font(.workbenchMetadata.weight(.semibold))
                    .workbenchTruncatedTitle(suggestion.targetTitle)
                  Text(suggestion.targetPath)
                    .font(.workbenchMetadata.monospaced())
                    .foregroundStyle(.workbenchSecondary)
                    .workbenchTruncatedIdentity(suggestion.targetPath)
                }
                Spacer(minLength: 0)
              }

              Text(suggestion.reason)
                .font(.workbenchMetadata)
                .foregroundStyle(.workbenchSecondary)
                .lineLimit(2)

              if !suggestion.sharedLabels.isEmpty {
                Text(suggestion.sharedLabels.joined(separator: "、"))
                  .font(.workbenchMetadata)
                  .foregroundStyle(.workbenchSecondary)
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
        .font(.workbenchMetadata.weight(.semibold))
        .foregroundStyle(.workbenchSecondary)

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
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
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
    .font(.workbenchMetadata.monospacedDigit())
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
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
        Text(card.siteName)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
        Text(card.urlText)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .lineLimit(1)
      }
      Text(card.title)
        .font(.workbenchBody.weight(.medium))
        .foregroundStyle(.primary)
        .workbenchTruncatedTitle(card.title, lineLimit: 2)
      Text(card.description)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
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
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(.workbenchSecondary)
          .lineLimit(1)
        Text(card.title)
          .font(.workbenchBody.weight(.semibold))
          .workbenchTruncatedTitle(card.title, lineLimit: 2)
        Text(card.description)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
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
          .font(.workbenchTitle3.weight(.bold))
        Text(card.siteName)
          .font(.workbenchMetadata.weight(.semibold))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkbenchSpacing.card)
      .padding(.top, WorkbenchSpacing.control)

      socialPreviewImage(card, placeholder: "X 卡片图片")
        .padding(.top, WorkbenchSpacing.control)

      VStack(alignment: .leading, spacing: 4) {
        Text(card.urlText)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .lineLimit(1)
        Text(card.title)
          .font(.workbenchBody.weight(.semibold))
          .workbenchTruncatedTitle(card.title, lineLimit: 2)
        Text(card.description)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
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
          .font(.workbenchTitle3)
        Text(placeholder)
          .font(.workbenchMetadata)
      }
      .foregroundStyle(.workbenchSecondary)
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
                .font(.workbenchMetadata.weight(.semibold))
              Text(item.status.localizedDisplayName)
                .font(.workbenchMetadata.weight(.medium))
                .foregroundStyle(socialPreviewReadinessForeground(item.status))
            }
            Text(item.message)
              .font(.workbenchMetadata)
              .foregroundStyle(.workbenchSecondary)
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
              .font(.workbenchMetadata.weight(.semibold))
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
            .font(.workbenchMetadata)
            .workbenchTruncatedTitle(item.title, lineLimit: 2)
          Text(item.body)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(3)
          Text(item.urlText)
            .font(.workbenchMetadata.monospaced())
            .foregroundStyle(.workbenchSecondary)
            .workbenchTruncatedIdentity(item.urlText)
          if !item.hashtagText.isEmpty {
            Text(item.hashtagText)
              .font(.workbenchMetadata)
              .foregroundStyle(.workbenchSecondary)
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
              .font(.workbenchMetadata.weight(.semibold))
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
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(2)
          Text(link.urlText)
            .font(.workbenchMetadata.monospaced())
            .foregroundStyle(.workbenchSecondary)
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
}

struct WorkspaceTaskChecksSection: View {
  let state: WorkspaceTaskChecksState
  let actions: WorkspaceTaskChecksActions
  @Environment(\.showPublishChecks) private var showPublishChecks

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

      InspectorSection("问题") {
        if state.issues.isEmpty {
          Label("当前文章检查通过", systemImage: "checkmark.circle")
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
        } else {
          PublishChecksLink(
            summary: String(
              localized: "\(state.errorCount) 个错误 · \(state.warningCount) 个警告"),
            action: showPublishChecks
          )
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
            .font(.workbenchBody.weight(.medium))
          Text(summary.statusMessage)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
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
        .font(.workbenchMetadata)

        ForEach(summary.issues.prefix(3)) { issue in
          let issueTitle = "\(issue.severity.localizedDisplayName) · \(issue.title)"
          Text(issueTitle)
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
            .workbenchTruncatedTitle(issueTitle)
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

/// Article issues are listed and fixed only in 发布检查; other surfaces link there.
private struct PublishChecksLink: View {
  let summary: String
  let action: (@MainActor () -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Text(summary)
        .font(.workbenchMetadata.monospacedDigit())
        .foregroundStyle(.workbenchSecondary)
      Spacer(minLength: 8)
      if let action {
        Button("在发布检查中查看") { action() }
          .buttonStyle(.link)
          .font(.workbenchMetadata)
          .accessibilityIdentifier("inspector-open-publish-checks")
      }
    }
  }
}
