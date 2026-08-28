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
  @ObservedObject private var summaryAI: WorkbenchMetadataSummaryFeatureFacade
  private let store: WorkbenchStore
  let state: WorkspaceTaskMetadataState
  let tagSuggestions: [String]
  let categorySuggestions: [String]
  @State private var isGeneratingSummary = false
  @State private var summaryGenerationMessage: String?
  @State private var summaryGenerationSucceeded = false
  @State private var summaryGenerationRequestID: UUID?
  @State private var summaryGenerationTask: Task<Void, Never>?
  @State private var isAddingDraftToProject = false
  @State private var slugText: String
  @FocusState private var isSlugFocused: Bool

  init(
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    state: WorkspaceTaskMetadataState,
    tagSuggestions: [String],
    categorySuggestions: [String]
  ) {
    _draft = draft
    self.store = store
    _summaryAI = ObservedObject(
      wrappedValue: WorkbenchMetadataSummaryFeatureFacade(store: store)
    )
    _slugText = State(initialValue: draft.wrappedValue.slug)
    self.state = state
    self.tagSuggestions = tagSuggestions
    self.categorySuggestions = categorySuggestions
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      InspectorSection("基础字段") {
        metadataField("标题") {
          TextField("输入文章标题", text: $draft.title)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("元数据标题")
            .accessibilityValue(draft.title.isEmpty ? "未填写" : draft.title)
        }
        metadataField("固定链接（Slug）") {
          TextField("例如 my-article", text: $slugText)
            .textFieldStyle(.roundedBorder)
            .focused($isSlugFocused)
            .onSubmit(commitSlugEdit)
            .onChange(of: isSlugFocused) { wasFocused, isFocused in
              if wasFocused && !isFocused {
                commitSlugEdit()
              }
            }
            .onChange(of: draft.id) { _, _ in
              slugText = draft.slug
            }
            .onChange(of: draft.slug) { _, currentSlug in
              if !isSlugFocused {
                slugText = currentSlug
              }
            }
            .accessibilityLabel("文章固定链接")
            .accessibilityValue(slugText.isEmpty ? "未填写" : slugText)
          if !draft.pendingSlugRedirectPaths.isEmpty {
            Button {
              store.selectSection(.contentHealth)
            } label: {
              Label(
                "已检测到旧地址，前往内容健康处理",
                systemImage: "arrow.triangle.branch"
              )
            }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityIdentifier("open-slug-change-resolution")
          }
        }
        summaryField
      }

      InspectorSection("分类") {
        TaxonomySuggestionField(
          title: "标签",
          values: $draft.tags,
          suggestions: tagSuggestions
        )
        TaxonomySuggestionField(
          title: "分类",
          values: $draft.categories,
          suggestions: categorySuggestions
        )
      }

      InspectorSection("补充元数据") {
        VStack(alignment: .leading, spacing: 14) {
          InspectorSection("发布时间与可见性") {
            metadataField("发布时间") {
              DatePicker(
                "发布时间", selection: $draft.date, displayedComponents: [.date, .hourAndMinute]
              )
              .labelsHidden()
              .accessibilityLabel("文章发布时间")
              .accessibilityValue(draft.date.formatted(date: .abbreviated, time: .shortened))
            }
            metadataField("可见性") {
              Picker("可见性", selection: $draft.visibility) {
                ForEach(ArticleVisibility.allCases) { visibility in
                  Label(visibility.localizedDisplayName, systemImage: visibility.systemImage)
                    .tag(visibility)
                }
              }
              .labelsHidden()
              .accessibilityLabel("文章可见性")
              .accessibilityValue(draft.visibility.localizedDisplayName)
            }
            Toggle("标记为草稿", isOn: $draft.draft)
              .accessibilityLabel("草稿状态")
              .accessibilityValue(draft.draft ? "草稿" : "非草稿")
          }

          InspectorSection("作者") {
            metadataField("作者") {
              TextField("多位作者用逗号分隔", text: authorsBinding)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("文章作者")
                .accessibilityValue(
                  draft.authors.isEmpty ? "未填写" : draft.authors.joined(separator: "，"))
            }
          }

          InspectorSection("状态与归属") {
            InspectorStatRow(title: "站点", value: state.siteName, systemImage: "globe")
            InspectorStatRow(
              title: "写作阶段", value: draft.status.localizedDisplayName,
              systemImage: draft.status.systemImage)
            InspectorStatRow(
              title: "站点稿件",
              value: siteDraftStatusDescription,
              systemImage: draft.draft ? "doc.badge.clock" : "doc.badge.checkmark"
            )
            InspectorStatRow(
              title: "本地保存",
              value: localSaveStatusDescription,
              systemImage: localSaveStatusSystemImage
            )
            InspectorStatRow(
              title: "远端同步",
              value: remoteSyncState.localizedDisplayName,
              systemImage: remoteSyncState.systemImage
            )

            Text(draft.repositoryPath?.normalizedRelativePath() ?? "计划路径：\(state.markdownPath)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .workbenchTruncatedIdentity(
                draft.repositoryPath?.normalizedRelativePath() ?? state.markdownPath,
                lineLimit: 3
              )

            if !draft.isGeneralDraft, draft.repositoryPath?.nilIfEmpty == nil {
              Button {
                addDraftToProject()
              } label: {
                if isAddingDraftToProject {
                  HStack(spacing: 6) {
                    ProgressView()
                      .controlSize(.small)
                    Text("正在加入项目")
                  }
                } else {
                  Label("加入站点项目", systemImage: "folder.badge.plus")
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .disabled(isAddingDraftToProject)
              .help("确认后才创建项目 Markdown；以后编辑会自动保存到该文件。")
              .accessibilityIdentifier("metadata-add-draft-to-project")
            }
          }
        }
      }
    }
    .onChange(of: draft.id) { _, _ in
      cancelSummaryGeneration()
      summaryGenerationMessage = nil
    }
    .onDisappear {
      cancelSummaryGeneration()
    }
  }

  private func commitSlugEdit() {
    guard slugText != draft.slug else { return }
    draft.slug = slugText
  }

  private var siteDraftStatusDescription: String {
    if draft.isGeneralDraft {
      return String(localized: "通用草稿，不属于站点")
    }
    return draft.draft
      ? String(localized: "网站草稿，默认不参与批量发布")
      : String(localized: "正式发布候选")
  }

  private var localSaveStatusDescription: String {
    if draft.isGeneralDraft {
      return String(localized: "已保存在软件")
    }
    switch store.siteDraftFileSaveStates[draft.id] {
    case .pending:
      return String(localized: "正在写入项目")
    case .saved:
      return String(localized: "已写入项目")
    case .failed(_, let message):
      return String(localized: "项目写入失败：\(message)")
    case nil:
      return draft.repositoryPath?.nilIfEmpty == nil
        ? String(localized: "仅保存在软件")
        : String(localized: "已绑定项目文件")
    }
  }

  private var localSaveStatusSystemImage: String {
    switch store.siteDraftFileSaveStates[draft.id] {
    case .pending: return "arrow.triangle.2.circlepath"
    case .saved: return "checkmark.circle"
    case .failed: return "exclamationmark.triangle"
    case nil: return draft.repositoryPath?.nilIfEmpty == nil ? "internaldrive" : "doc"
    }
  }

  private var remoteSyncState: DraftRepositorySyncState {
    draft.repositorySyncState(for: store.profile(for: draft))
  }

  private func addDraftToProject() {
    guard !isAddingDraftToProject else { return }
    let draftID = draft.id
    isAddingDraftToProject = true
    Task { @MainActor in
      _ = await store.writeSiteDraftToProject(draftID: draftID)
      if let latest = store.drafts.first(where: { $0.id == draftID }) {
        draft = latest
      }
      isAddingDraftToProject = false
    }
  }

  private var summaryField: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .center, spacing: 8) {
        Text("摘要")
          .font(.callout)
          .foregroundStyle(.secondary)

        Spacer(minLength: 0)

        Button(action: generateAISummary) {
          if isGeneratingSummary {
            HStack(spacing: 5) {
              ProgressView()
                .controlSize(.small)
              Text("生成中")
            }
          } else {
            Label(summaryAIButtonTitle, systemImage: "sparkles")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!summaryAIAvailability.isEnabled)
        .help(summaryAIAvailability.unavailableReason ?? summaryAIButtonHelp)
        .accessibilityIdentifier("metadata-summary-ai-button")
        .accessibilityLabel("AI 自动生成摘要")
        .accessibilityValue(isGeneratingSummary ? "生成中" : summaryAIButtonTitle)
      }

      TextField("输入用于列表和搜索的文章摘要", text: $draft.summary, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...5)
        .accessibilityLabel("文章摘要")
        .accessibilityValue(draft.summary.isEmpty ? "未填写" : draft.summary)

      if let summaryGenerationMessage {
        Label {
          Text(verbatim: summaryGenerationMessage)
        } icon: {
          Image(
            systemName: summaryGenerationSucceeded ? "checkmark.circle" : "exclamationmark.triangle"
          )
        }
        .font(.caption)
        .foregroundStyle(
          summaryGenerationSucceeded ? WorkbenchTheme.success : WorkbenchTheme.warning
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var summaryAIButtonTitle: String {
    draft.summary.trimmedForPublishing.isEmpty
      ? String(localized: "AI 生成")
      : String(localized: "AI 重写")
  }

  private var summaryAIButtonHelp: String {
    draft.summary.trimmedForPublishing.isEmpty
      ? String(localized: "根据文章标题和正文自动生成摘要")
      : String(localized: "根据当前文章重新生成并替换摘要")
  }

  private var summaryAIAvailability: AIPublishingActionAvailabilityPresentation {
    let profile = store.profile(for: draft)
    let config = summaryAI.providerConfig(for: profile)
    let isAIEnabled = !config.requiresAPIKey || summaryAI.tokenAvailability.hasToken
    return AIPublishingActionAvailabilityService.presentation(
      for: .suggestSummary,
      draft: draft,
      isAIEnabled: isAIEnabled,
      activeAction: isGeneratingSummary || summaryAI.isActionRunning ? .suggestSummary : nil
    )
  }

  private func generateAISummary() {
    guard summaryAIAvailability.isEnabled else { return }

    cancelSummaryGeneration()
    let requestedDraft = draft
    let originalSummary = requestedDraft.summary
    let requestID = UUID()
    summaryGenerationRequestID = requestID
    isGeneratingSummary = true
    summaryGenerationMessage = nil
    summaryGenerationSucceeded = false

    summaryGenerationTask = Task { @MainActor in
      defer {
        if summaryGenerationRequestID == requestID {
          isGeneratingSummary = false
          summaryGenerationRequestID = nil
          summaryGenerationTask = nil
        }
      }

      let result = await store.performAIAction(.suggestSummary, draft: requestedDraft)
      guard !Task.isCancelled,
        summaryGenerationRequestID == requestID,
        draft.id == requestedDraft.id
      else {
        return
      }
      guard let result,
        let generatedSummary =
          AIPublishingMetadataActionSuggestionFactory
          .suggestion(from: result)?
          .summary
      else {
        summaryGenerationMessage =
          summaryAI.actionMessage
          ?? String(localized: "AI 没有返回可用的摘要。")
        return
      }
      guard let latestDraft = store.drafts.first(where: { $0.id == requestedDraft.id }) else {
        summaryGenerationMessage = String(localized: "找不到当前文章，摘要未应用。")
        return
      }
      guard latestDraft.summary == originalSummary else {
        summaryGenerationMessage = String(localized: "摘要在生成期间已被修改，未自动覆盖。")
        return
      }
      guard
        store.applyAIMetadataSuggestion(
          field: .summary,
          value: generatedSummary,
          draft: latestDraft
        ) != nil
      else {
        summaryGenerationMessage =
          summaryAI.actionMessage
          ?? String(localized: "AI 没有返回新的摘要。")
        return
      }

      summaryGenerationSucceeded = true
      summaryGenerationMessage = String(localized: "摘要已自动生成并填写。")
    }
  }

  private func cancelSummaryGeneration() {
    summaryGenerationTask?.cancel()
    summaryGenerationTask = nil
    summaryGenerationRequestID = nil
    isGeneratingSummary = false
  }

  private func metadataField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

private struct WorkspaceTaskSEOPresentationKey: Hashable {
  let draftID: UUID
  let editorMetadataRevision: UInt64
  let updatedAt: Date
  let profile: SiteProfile
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
          title: "标题", value: "\(report.titleCharacterCount) 字", systemImage: "textformat.size")
        InspectorStatRow(
          title: "摘要", value: "\(report.summaryCharacterCount) 字", systemImage: "text.alignleft")
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
                .padding(.top, 7)
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
          InspectorStatRow(
            title: "标题", value: "\(snapshot.titleCharacterCount) 字", systemImage: "textformat.size")
          InspectorStatRow(
            title: "描述", value: "\(snapshot.descriptionCharacterCount) 字",
            systemImage: "text.alignleft")
          InspectorStatRow(
            title: "图片",
            value: snapshot.imageDimensions?.workbenchDimensionText
              ?? (snapshot.imagePath == nil ? "未设置" : "已设置"), systemImage: "photo")
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
              socialPreviewCard(card)
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
          .padding(8)
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
            .padding(8)
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

  private func socialPreviewCard(_ card: SEOSocialPreviewCard) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(card.kind.localizedDisplayName, systemImage: card.kind.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Label(
          card.titleBudgetText,
          systemImage: card.isTitleWithinBudget ? "checkmark.circle" : "exclamationmark.triangle"
        )
        .foregroundStyle(card.isTitleWithinBudget ? Color.secondary : WorkbenchTheme.warning)
        Label(
          card.descriptionBudgetText,
          systemImage: card.isDescriptionWithinBudget
            ? "checkmark.circle" : "exclamationmark.triangle"
        )
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
      .font(.caption)
      Text(card.title)
        .font(.caption.weight(.semibold))
        .workbenchTruncatedIdentity(card.title, lineLimit: 2)
      Text(card.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }
    .padding(8)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("社交卡片：\(card.kind.localizedDisplayName)")
    .accessibilityValue("\(card.title)。\(card.description)")
  }

  private func socialPreviewReadinessSection(_ snapshot: SEOSocialPreviewSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          copy(snapshot.socialShareChecklistMarkdown, message: "已复制 SEO / Social 检查清单。")
        } label: {
          Label("复制清单", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("复制 SEO / Social 检查清单")
        .accessibilityLabel("复制 SEO Social 检查清单")

        Button {
          copy(snapshot.metaTags.htmlBlock, message: "已复制社交预览 Meta HTML。")
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
    .padding(8)
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
        .padding(8)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(8)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func socialDebugLinkSection(_ links: [SEOSocialPreviewDebugLink]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Spacer(minLength: 0)
        Button {
          copy(links.map(\.clipboardLine).joined(separator: "\n"), message: "已复制外部社交调试链接。")
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text(link.urlText)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(link.urlText)
        }
        .padding(8)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      }
    }
    .padding(8)
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
    .padding(.vertical, 4)
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
           || deploymentStatus.signals.contains(where: { !$0.logExcerpt.isEmpty }) {
        WorkspaceDeploymentLogInspectorSection(snapshot: deploymentStatus)
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
    .padding(8)
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
        .foregroundStyle(Color.accentColor)
        .fixedSize(horizontal: true, vertical: false)
    }
  }
}

struct WorkspaceTaskImageState {
  let report: ImageWorkbenchReport?
  let actionMessage: String?
  let focusedAttachmentID: UUID?
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

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("当前文章") {
        if let report {
          InspectorStatRow(title: "图片", value: "\(report.items.count)", systemImage: "photo")
          InspectorStatRow(
            title: "缺 alt", value: "\(report.missingAltTextCount)", systemImage: "text.quote")
          InspectorStatRow(
            title: "缺源图", value: "\(report.missingSourceCount)", systemImage: "xmark.octagon")
          InspectorStatRow(
            title: "可压缩 JPEG", value: "\(report.optimizableJPEGCount)",
            systemImage: "arrow.down.forward")
          Label(
            report.coverStatus.state.localizedDisplayName,
            systemImage: report.coverStatus.state.systemImage
          )
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
              caption: attachmentStringBinding(for: attachment.id, keyPath: \.caption),
              isCover: attachmentCoverBinding(for: attachment.id),
              isFocused: state.focusedAttachmentID == attachment.id
            )
            .id(attachment.id)
          }
        }
      }

      InspectorSection("图片工作台") {
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

  private func attachmentCoverBinding(for attachmentID: UUID) -> Binding<Bool> {
    Binding(
      get: { draft.coverAttachmentID == attachmentID },
      set: { isCover in
        if isCover {
          draft.coverAttachmentID = attachmentID
        } else if draft.coverAttachmentID == attachmentID {
          draft.coverAttachmentID = nil
        }
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
  @Binding var isCover: Bool
  let isFocused: Bool

  @FocusState private var isAltFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(attachment.originalFilename)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(attachment.originalFilename)

        if item?.isCover == true {
          Image(systemName: "star.fill")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: item?.fileExists == false ? "xmark.octagon" : "checkmark.circle")
          .foregroundStyle(item?.fileExists == false ? WorkbenchTheme.risk : Color.secondary)
      }

      Text(attachment.relativePublishPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(attachment.relativePublishPath, lineLimit: 2)

      TextField("Alt", text: $altText)
        .textFieldStyle(.roundedBorder)
        .focused($isAltFocused)
        .accessibilityLabel("图片 Alt 文本")
        .accessibilityValue(altText.isEmpty ? "未填写" : altText)

      TextField("Caption", text: $caption)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Caption")
        .accessibilityValue(caption.isEmpty ? "未填写" : caption)

      Toggle("设为文章封面", isOn: $isCover)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
    .padding(8)
    .background(
      isFocused ? Color.accentColor.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      if isFocused {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
      }
    }
    .onAppear {
      if isFocused {
        isAltFocused = true
      }
    }
    .onChange(of: isFocused) { _, shouldFocus in
      if shouldFocus {
        isAltFocused = true
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片元数据 \(attachment.originalFilename)")
    .accessibilityValue(item?.fileExists == false ? "源图缺失" : "源图可用")
  }
}
