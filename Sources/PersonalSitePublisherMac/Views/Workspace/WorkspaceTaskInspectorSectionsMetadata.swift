import AppKit
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskMetadataSection: View {
  @Binding var draft: ArticleDraft
  @Binding private var isAdvancedExpanded: Bool
  @ObservedObject private var summaryAI: WorkbenchMetadataSummaryFeatureFacade
  private let store: WorkbenchStore
  let tagSuggestions: [String]
  let categorySuggestions: [String]
  @State private var isGeneratingSummary = false
  @State private var summaryGenerationMessage: String?
  @State private var summaryGenerationSucceeded = false
  @State private var summaryGenerationRequestID: UUID?
  @State private var summaryGenerationTask: Task<Void, Never>?
  @State private var isAddingDraftToProject = false
  @State private var provenancePresentationCache = ArticleProvenancePresentationCache()
  @State private var slugText: String
  @State private var slugDraftID: UUID
  @State private var isSummaryAIUnavailablePresented = false
  @State private var isOwnershipExpanded = false
  @FocusState private var isSlugFocused: Bool
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction

  init(
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    tagSuggestions: [String],
    categorySuggestions: [String],
    isAdvancedExpanded: Binding<Bool>
  ) {
    _draft = draft
    _isAdvancedExpanded = isAdvancedExpanded
    self.store = store
    _summaryAI = ObservedObject(
      wrappedValue: WorkbenchMetadataSummaryFeatureFacade(store: store)
    )
    _slugText = State(initialValue: draft.wrappedValue.slug)
    _slugDraftID = State(initialValue: draft.wrappedValue.id)
    self.tagSuggestions = tagSuggestions
    self.categorySuggestions = categorySuggestions
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      summaryField
        .id(PublishMetadataFieldAnchor.id(for: "summary"))
        .id(PublishMetadataFieldAnchor.id(for: "title"))

      InspectorSection("标签与分类") {
        TaxonomySuggestionField(
          title: "标签",
          addPrompt: "添加标签…",
          values: $draft.tags,
          suggestions: tagSuggestions
        )
        .id(draft.id)
        .id(PublishMetadataFieldAnchor.id(for: "tags"))

        TaxonomySuggestionField(
          title: "分类",
          addPrompt: "添加分类…",
          values: $draft.categories,
          suggestions: categorySuggestions
        )
        .id(draft.id)
      }

      InspectorSection("发布") {
        metadataField("发布时间") {
          DatePicker(
            "发布时间", selection: $draft.date, displayedComponents: [.date, .hourAndMinute]
          )
          .labelsHidden()
          .accessibilityLabel("文章发布时间")
          .accessibilityValue(draft.date.formatted(date: .abbreviated, time: .shortened))
        }
        .id(PublishMetadataFieldAnchor.id(for: "date"))
        ArticleStatePicker(draft: $draft, store: store)
          .id(PublishMetadataFieldAnchor.id(for: "draft"))
      }

      if !draft.isGeneralDraft, draft.repositoryPath?.nilIfEmpty == nil {
        addDraftToProjectButton
      }
      if SlugService.isFallbackSlug(draft.slug) {
        timestampSlugNotice
      }
      InspectorDisclosureSection("高级", isExpanded: advancedExpansionBinding) {
        if isAdvancedExpanded {
          advancedFields
        }
      }
      .accessibilityIdentifier("article-metadata-advanced")
      if remoteSyncState.hasSyncProblem || draft.translationLink != nil {
        InspectorDisclosureSection("状态与归属", isExpanded: $isOwnershipExpanded) {
          if remoteSyncState.hasSyncProblem {
            InspectorStatRow(
              title: "远端同步",
              value: remoteSyncState.localizedDisplayName,
              systemImage: remoteSyncState.systemImage
            )
          }

          if let link = draft.translationLink {
            TranslationRelationshipSection(draft: $draft, store: store, link: link)
          }
        }
      }
    }
    .onChange(of: draft.id) { _, _ in
      cancelSummaryGeneration()
      summaryGenerationMessage = nil
      slugText = draft.slug
      slugDraftID = draft.id
    }
    .onChange(of: draft.slug) { _, currentSlug in
      if !isSlugFocused || !isAdvancedExpanded { slugText = currentSlug }
    }
    .onDisappear {
      // Folding the group must commit a focused Slug before its field is removed.
      commitSlugEdit()
      cancelSummaryGeneration()
    }
  }

  private var advancedExpansionBinding: Binding<Bool> {
    Binding(
      get: { isAdvancedExpanded },
      set: { expanded in
        if expanded {
          slugText = draft.slug
          slugDraftID = draft.id
        } else {
          commitSlugEdit()
        }
        isAdvancedExpanded = expanded
      }
    )
  }

  private var advancedFields: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      if !draft.isGeneralDraft {
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
          .accessibilityIdentifier("article-visibility-picker")
          Text("私密文章仍可同步到仓库的私密目录；更改状态不会改变可见性。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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
          .accessibilityLabel("文章固定链接")
          .accessibilityValue(slugText.isEmpty ? String(localized: "未填写") : slugText)
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
      .id(PublishMetadataFieldAnchor.id(for: "slug"))
      metadataField("作者") {
        TextField("多位作者用逗号分隔", text: authorsBinding)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("文章作者")
          .accessibilityValue(
            draft.authors.isEmpty
              ? String(localized: "未填写") : draft.authors.joined(separator: "，"))
      }
      InspectorSection("创作信息") {
        metadataField("创作来源") {
          Picker("创作来源", selection: provenanceBinding) {
            ForEach(ArticleProvenance.allCases) { provenance in
              Label(provenance.localizedDisplayName, systemImage: provenance.systemImage)
                .tag(provenance)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .help(provenanceHelpText)
          .accessibilityIdentifier("article-provenance-picker")
          .accessibilityLabel("文章创作来源")
          .accessibilityValue(selectedProvenance.localizedDisplayName)
          .accessibilityHint(provenanceHelpText)
        }

        if selectedProvenance != .humanOriginal {
          Text(provenanceHelpText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      TranslationCreationSection(draft: draft, store: store)
      ArticlePublishReminderSection(reminderAt: $draft.publishReminderAt, draftID: $draft.id)
    }
  }

  private var timestampSlugNotice: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.icon) {
      Label("Slug 使用时间戳", systemImage: "link")
        .font(.caption.weight(.medium))
      Text(verbatim: draft.slug)
        .font(.caption.monospaced())
        .textSelection(.enabled)
      Text("可用标题生成更易读的网址，也可以保留此网址发布。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("用标题生成") {
        commitSlugEdit()
        guard SlugService.isFallbackSlug(draft.slug), let slug = suggestedTitleSlug else { return }
        slugText = slug
        draft.slug = slug
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(suggestedTitleSlug == nil)
      .accessibilityIdentifier("article-generate-slug-from-title")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("article-timestamp-slug-notice")
  }

  private var suggestedTitleSlug: String? {
    guard !draft.title.trimmedForPublishing.isEmpty else { return nil }
    let slug = SlugService.slug(from: draft.title)
    return SlugService.isFallbackSlug(slug) || slug == draft.slug ? nil : slug
  }

  private var selectedProvenance: ArticleProvenance {
    provenancePresentationCache.provenance(
      draftID: draft.id,
      tags: draft.tags,
      bodyMarkdown: draft.bodyMarkdown
    ) {
      ArticleProvenanceService().provenance(for: draft)
    }
  }

  private var provenanceBinding: Binding<ArticleProvenance> {
    Binding(
      get: { selectedProvenance },
      set: { provenance in
        store.applyArticleProvenance(provenance, to: draft.id)
      }
    )
  }

  private var provenanceHelpText: String {
    switch selectedProvenance {
    case .humanOriginal:
      return String(localized: "真人原稿不会写入来源标签，也不会生成创作说明。")
    case .aiAssisted, .aiAuthored, .hybrid:
      return String(localized: "RepoPress 会维护对应标签，并在正文顶部生成可见的创作说明。")
    }
  }

  private func commitSlugEdit() {
    guard slugDraftID == draft.id, slugText != draft.slug else { return }
    draft.slug = slugText
  }

  private var addDraftToProjectButton: some View {
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

        Button(action: summaryAIButtonAction) {
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
        .disabled(isGeneratingSummary)
        .help(summaryAIUnavailableReason ?? summaryAIButtonHelp)
        .accessibilityIdentifier("metadata-summary-ai-button")
        .accessibilityLabel(summaryAIButtonTitle)
        .accessibilityValue(
          isGeneratingSummary
            ? String(localized: "生成中")
            : (summaryAIUnavailableReason ?? summaryAIButtonTitle)
        )
        // Explain on demand instead of showing a permanent warning under
        // every article when AI is not set up.
        .popover(isPresented: $isSummaryAIUnavailablePresented, arrowEdge: .bottom) {
          summaryAIUnavailablePopover
        }
      }

      TextField("输入用于列表和搜索的文章摘要", text: $draft.summary, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(2...5)
        .fixedSize(horizontal: false, vertical: true)
        .padding(WorkbenchSpacing.control)
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityLabel("文章摘要")
        .accessibilityValue(draft.summary.isEmpty ? String(localized: "未填写") : draft.summary)
        .accessibilityIdentifier("article-summary-field")

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

  private func summaryAIButtonAction() {
    if summaryAIAvailability.isEnabled {
      generateAISummary()
    } else {
      isSummaryAIUnavailablePresented = true
    }
  }

  private var summaryAIUnavailablePopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(
        summaryAIUnavailableReason ?? String(localized: "AI 暂不可用"),
        systemImage: "info.circle"
      )
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("metadata-summary-ai-unavailable-reason")
      Button("前往 AI 设置") {
        isSummaryAIUnavailablePresented = false
        SettingsNavigation.present(
          destination: .tab(.ai),
          workspaceAction: settingsWorkspaceCommandAction
        ) {
          openSettings()
        }
      }
      .accessibilityIdentifier("metadata-summary-ai-open-settings")
    }
    .padding(WorkbenchSpacing.content)
    .frame(width: 240, alignment: .leading)
  }

  private var summaryAIButtonTitle: String {
    draft.summary.trimmedForPublishing.isEmpty
      ? String(localized: "AI 生成")
      : String(localized: "AI 改写")
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

  private var summaryAIUnavailableReason: String? {
    let profile = store.profile(for: draft)
    let config = summaryAI.providerConfig(for: profile)
    return WorkspaceTaskInspectorPresentation.summaryAIUnavailableReason(
      availability: summaryAIAvailability,
      requiresAPIKey: config.requiresAPIKey,
      hasAPIKey: summaryAI.tokenAvailability.hasToken
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

      guard !Task.isCancelled, summaryGenerationRequestID == requestID,
        draft.id == requestedDraft.id
      else { return }
      let result = await store.performAIAction(.suggestSummary, draft: requestedDraft)
      guard !Task.isCancelled,
        summaryGenerationRequestID == requestID,
        draft.id == requestedDraft.id
      else {
        return
      }
      // nil also represents a cancelled/superseded request. Do not relabel it
      // with another request's global action message.
      guard let result else { return }
      guard
        let generatedSummary =
          AIPublishingMetadataActionSuggestionFactory
          .suggestion(from: result)?
          .summary
      else {
        summaryGenerationMessage = String(localized: "AI 没有返回可用的摘要。")
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
