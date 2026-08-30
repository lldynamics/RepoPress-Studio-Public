import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceCommandPalette: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @ObservedObject private var commandPresentation: WorkbenchCommandPresentationFeatureFacade
  @ObservedObject private var draftListState: DraftListStore
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  let store: WorkbenchStore
  let editorCommands: MarkdownEditorCommandActions?
  let onToggleFocusMode: () -> Void
  @AppStorage("workspaceCommandPaletteRecentAIPromptIDs")
  private var recentAIPromptIDs = ""
  @AppStorage("workspaceCommandPaletteRecentSettingsItemIDs")
  private var recentSettingsItemIDs = ""
  @State private var query = ""
  @State private var scope: WorkspaceUnifiedSearchScope = .all
  @State private var selectedResultID: String?
  @FocusState private var isSearchFocused: Bool

  init(
    store: WorkbenchStore,
    editorCommands: MarkdownEditorCommandActions? = nil,
    onToggleFocusMode: @escaping () -> Void
  ) {
    self.store = store
    self.editorCommands = editorCommands
    self.onToggleFocusMode = onToggleFocusMode
    _commandPresentation = ObservedObject(wrappedValue: store.commandPresentation)
    _draftListState = ObservedObject(wrappedValue: store.draftList)
    _shell = ObservedObject(wrappedValue: store.shell)
  }

  var body: some View {
    let snapshot = makeSnapshot()
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command")
          .foregroundStyle(.secondary)
        TextField("搜索文章、AI 功能、工作区或命令…", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isSearchFocused)
          .accessibilityLabel("搜索文章、AI 功能、工作区或命令…")
          .onSubmit(performSelectedResult)
        Text("⌘P")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
      .padding(16)

      Picker("搜索范围", selection: $scope) {
        ForEach(WorkspaceUnifiedSearchScope.allCases) { scope in
          Text(scope.title).tag(scope)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      .accessibilityLabel("搜索范围")
      .accessibilityIdentifier("workspace-command-palette-scope")

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if !snapshot.commands.isEmpty {
              paletteSection(String(localized: "命令")) {
                ForEach(snapshot.commands) { command in
                  row(
                    id: commandResultID(command),
                    title: command.title,
                    detail: command.detail,
                    systemImage: command.systemImage,
                    shortcut: command.shortcut,
                    action: command.action
                  )
                }
              }
            }

            if !snapshot.aiPrompts.isEmpty {
              paletteSection(String(localized: "AI 功能")) {
                ForEach(snapshot.aiPrompts) { prompt in
                  row(
                    id: aiPromptResultID(prompt),
                    title: prompt.localizedDisplayName,
                    detail: prompt.group.localizedDisplayName + " · "
                      + prompt.group.localizedDetail,
                    systemImage: prompt.systemImage,
                    action: { openAIPrompt(prompt) }
                  )
                }
              }
            }

            if !snapshot.drafts.isEmpty {
              paletteSection(String(localized: "文章")) {
                ForEach(snapshot.drafts) { draft in
                  let display = store.privateContentDisplay(for: draft)
                  row(
                    id: draftResultID(draft),
                    title: display.title.nilIfEmpty ?? String(localized: "未命名文章"),
                    detail: display.isMasked ? display.summary : draft.slug,
                    systemImage: draft.id == commandPresentation.selectedDraftID
                      ? "doc.text.fill" : "doc.text",
                    action: { openDraft(draft.id) }
                  )
                }
              }
            }

            if !snapshot.resourceSections.isEmpty {
              paletteSection(String(localized: "资料")) {
                ForEach(snapshot.resourceSections) { section in
                  row(
                    id: sectionResultID(section),
                    title: localizedSectionTitle(section),
                    detail: section.keyboardShortcutLabel,
                    systemImage: section.systemImage,
                    action: { openSection(section) }
                  )
                }
              }
            }

            if !snapshot.rssSections.isEmpty {
              paletteSection("RSS") {
                ForEach(snapshot.rssSections) { section in
                  row(
                    id: sectionResultID(section),
                    title: localizedSectionTitle(section),
                    detail: section.keyboardShortcutLabel,
                    systemImage: section.systemImage,
                    action: { openSection(section) }
                  )
                }
              }
            }

            if !snapshot.workspaceSections.isEmpty {
              paletteSection(String(localized: "工作区")) {
                ForEach(snapshot.workspaceSections) { section in
                  row(
                    id: sectionResultID(section),
                    title: localizedSectionTitle(section),
                    detail: section.keyboardShortcutLabel,
                    systemImage: section.systemImage,
                    action: { openSection(section) }
                  )
                }
              }
            }

            if !snapshot.settings.isEmpty {
              paletteSection(String(localized: "设置")) {
                ForEach(snapshot.settings) { item in
                  row(
                    id: settingsResultID(item),
                    title: item.sectionTitle,
                    detail: item.detail,
                    systemImage: item.systemImage,
                    action: { openSettingsItem(item) }
                  )
                }
              }
            }

            if snapshot.results.isEmpty {
              ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, minHeight: 220)
            }
          }
          .padding(16)
        }
        .onChange(of: selectedResultID) { _, resultID in
          guard let resultID else { return }
          proxy.scrollTo(resultID, anchor: .center)
        }
      }
    }
    .frame(width: 620, height: 560)
    .onAppear {
      isSearchFocused = true
      synchronizeSelection()
    }
    .onChange(of: query) { _, _ in
      synchronizeSelection()
    }
    .onChange(of: scope) { _, _ in
      synchronizeSelection()
    }
    .onChange(of: shell.isQuickHideActive) { _, isActive in
      if isActive {
        dismiss()
      }
    }
    .onKeyPress(.downArrow) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveSelection(by: -1)
      return .handled
    }
    .onExitCommand {
      dismiss()
    }
    .accessibilityLabel("命令面板")
    .accessibilityIdentifier("workspace-command-palette")
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func makeSnapshot() -> PaletteSnapshot {
    let normalized = normalizedQuery
    let commandItems =
      scope.includesCommands
      ? commands.filter {
        normalized.isEmpty
          || $0.title.localizedStandardContains(normalized)
          || $0.detail.localizedStandardContains(normalized)
      } : []
    let promptItems = scope.includesCommands ? matchingAIPrompts(for: normalized) : []
    let matchingSections = WorkspaceUnifiedSearchPresentation.matchingSections(
      WorkspaceNavigationPresentation.commandPaletteSections + [.images],
      query: normalized,
      scope: scope
    )
    let resourceSections = matchingSections.filter {
      $0 == .library || $0 == .images || $0 == .siteStarter
    }
    let rssSections = matchingSections.filter { $0 == .rss }
    let workspaceSections = matchingSections.filter {
      !resourceSections.contains($0) && !rssSections.contains($0)
    }
    let drafts =
      scope.includesArticles
      ? Array(
        draftListState.searchIndex(for: .allDrafts)
          .matching(query: normalized)
          .filter { draft in
            normalized.isEmpty
              || store.matchesPrivacyProtectedDraftSearch(
                draft,
                query: normalized,
                profile: store.profile(for: draft)
              )
          }
          .prefix(12)
      ) : []
    let settings =
      scope.includesSettings
      ? WorkspaceUnifiedSearchPresentation.matchingSettings(
        query: normalized,
        recentItemIDs: recentSettingsItemIDList
      )
      : []
    var results: [PaletteResult] = []
    results.reserveCapacity(
      commandItems.count + promptItems.count + drafts.count + resourceSections.count
        + rssSections.count + workspaceSections.count + settings.count
    )
    for command in commandItems {
      results.append(PaletteResult(id: commandResultID(command), action: command.action))
    }
    for prompt in promptItems {
      results.append(PaletteResult(id: aiPromptResultID(prompt), action: { openAIPrompt(prompt) }))
    }
    for draft in drafts {
      results.append(PaletteResult(id: draftResultID(draft), action: { openDraft(draft.id) }))
    }
    for section in resourceSections + rssSections + workspaceSections {
      results.append(PaletteResult(id: sectionResultID(section), action: { openSection(section) }))
    }
    for item in settings {
      results.append(PaletteResult(id: settingsResultID(item), action: { openSettingsItem(item) }))
    }
    return PaletteSnapshot(
      commands: commandItems,
      aiPrompts: promptItems,
      drafts: drafts,
      resourceSections: resourceSections,
      rssSections: rssSections,
      workspaceSections: workspaceSections,
      settings: settings,
      results: results)
  }

  private func matchingAIPrompts(for query: String) -> [AIPublishingQuickPrompt] {
    let candidates: [AIPublishingQuickPrompt]
    if query.isEmpty {
      let editing =
        editorCommands?.canRewriteSelection == true
        ? AIPublishingQuickPrompt.allCases.filter { $0.group == .editing }
        : []
      candidates = Array(
        stablyRankedAIPrompts(editing + AIPublishingQuickPrompt.primaryPrompts)
          .prefix(8)
      )
    } else {
      candidates = AIPublishingQuickPrompt.allCases.filter { prompt in
        prompt.localizedDisplayName.localizedStandardContains(query)
          || prompt.group.localizedDisplayName.localizedStandardContains(query)
          || prompt.group.localizedDetail.localizedStandardContains(query)
          || prompt.prompt.localizedStandardContains(query)
      }
    }
    return stablyRankedAIPrompts(candidates)
  }

  private var commands: [PaletteCommand] {
    var items: [PaletteCommand] = [
      registeredAutomationCommand(.createDraft, shortcut: "⌘N") {
        store.createDraft()
        store.selectSection(.writing)
        dismiss()
      },
      registeredAutomationCommand(.saveWorkbench, shortcut: "⌘S") {
        store.save()
        dismiss()
      },
      registeredAutomationCommand(.runPreflight) {
        store.runPreflight()
        store.selectSection(.contentHealth)
        dismiss()
      },
      PaletteCommand(
        id: "workspace:library",
        title: String(localized: "打开资料库"),
        detail: String(localized: "查找并管理写作资料"),
        systemImage: "books.vertical"
      ) {
        store.selectSection(.library)
        dismiss()
      },
      PaletteCommand(
        id: "workspace:images",
        title: String(localized: "打开图片工作台"),
        detail: String(localized: "管理文章图片与压缩设置"),
        systemImage: "photo.on.rectangle"
      ) {
        store.selectSection(.images)
        dismiss()
      },
      PaletteCommand(
        id: "workspace:focus-mode",
        title: String(localized: "切换专注写作"),
        detail: String(localized: "使用顶部专注按钮或 ⇧⌘F"),
        systemImage: "scope",
        shortcut: "⇧⌘F"
      ) {
        onToggleFocusMode()
        dismiss()
      },
    ]

    if let editorCommands {
      items.append(contentsOf: [
        PaletteCommand(
          id: "editor:find-replace",
          title: String(localized: "查找与替换"),
          detail: String(localized: "在当前文章中查找或替换文本"),
          systemImage: "text.magnifyingglass",
          shortcut: "⌘F"
        ) {
          editorCommands.showFindReplace()
          dismiss()
        },
        PaletteCommand(
          id: "editor:snippets",
          title: String(localized: "打开片段库"),
          detail: String(localized: "插入正文片段或文章模板"),
          systemImage: "text.badge.plus"
        ) {
          editorCommands.showSnippets()
          dismiss()
        },
        PaletteCommand(
          id: "editor:insert-images",
          title: String(localized: "插入图片"),
          detail: String(localized: "把本地图片导入当前文章"),
          systemImage: "photo.badge.plus"
        ) {
          editorCommands.insertImages()
          dismiss()
        },
        PaletteCommand(
          id: "editor:preflight",
          title: String(localized: "运行当前文章发布检查"),
          detail: String(localized: "检查元数据、链接、图片与公开风险"),
          systemImage: "checkmark.shield"
        ) {
          editorCommands.runPreflight()
          dismiss()
        },
        PaletteCommand(
          id: "editor:bold",
          title: String(localized: "切换粗体"),
          detail: String(localized: "为当前选区添加或移除粗体"),
          systemImage: "bold",
          shortcut: "⌘B"
        ) {
          editorCommands.applyFormatting(.bold)
          dismiss()
        },
        PaletteCommand(
          id: "editor:italic",
          title: String(localized: "切换斜体"),
          detail: String(localized: "为当前选区添加或移除斜体"),
          systemImage: "italic",
          shortcut: "⌘I"
        ) {
          editorCommands.applyFormatting(.italic)
          dismiss()
        },
        PaletteCommand(
          id: "editor:link",
          title: String(localized: "插入或移除链接"),
          detail: String(localized: "切换当前选区的 Markdown 链接"),
          systemImage: "link",
          shortcut: "⌘K"
        ) {
          editorCommands.applyFormatting(.link)
          dismiss()
        },
      ])

      if editorCommands.canRewriteSelection {
        items.insert(
          PaletteCommand(
            id: "editor:rewrite-selection",
            title: String(localized: "AI 改写当前选区"),
            detail: String(localized: "生成可预览、可拒绝的选区改写"),
            systemImage: "wand.and.stars",
            shortcut: "⌥⌘R"
          ) {
            editorCommands.rewriteSelection()
            dismiss()
          },
          at: 0
        )
      }
    }

    items.insert(
      PaletteCommand(
        id: "ai:open-chat",
        title: String(localized: "打开 AI 对话"),
        detail: String(localized: "在右侧继续当前文章的 AI 对话"),
        systemImage: "sparkles",
        shortcut: "⌥⌘A"
      ) {
        guard let draftID = commandPresentation.selectedDraftID else { return }
        store.ai.openChatWorkspace(for: draftID)
        dismiss()
      },
      at: min(3, items.count)
    )

    return items
  }

  private func registeredAutomationCommand(
    _ command: WorkbenchAutomationCommandID,
    shortcut: String? = nil,
    action: @escaping () -> Void
  ) -> PaletteCommand {
    guard let descriptor = WorkbenchAutomationRegistry.descriptor(for: command) else {
      return PaletteCommand(
        id: "automation:\(command.rawValue)",
        title: command.rawValue,
        detail: "",
        systemImage: "questionmark.circle",
        shortcut: shortcut,
        action: action
      )
    }
    return PaletteCommand(
      id: "automation:\(command.rawValue)",
      title: descriptor.title,
      detail: descriptor.detail,
      systemImage: descriptor.systemImage,
      shortcut: shortcut,
      action: action
    )
  }

  private func paletteSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func row(
    id: String,
    title: String,
    detail: String,
    systemImage: String,
    shortcut: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    let isSelected = selectedResultID == id
    return Button {
      selectedResultID = id
      action()
    } label: {
      HStack(spacing: 11) {
        Image(systemName: systemImage)
          .frame(width: 22)
          .foregroundStyle(isSelected ? WorkbenchTheme.navigationSelection : WorkbenchTheme.primary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
            .workbenchTruncatedIdentity(title)
          if !detail.isEmpty {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        if let shortcut {
          Text(shortcut)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(
        isSelected
          ? WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground)
          : Color.clear,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
    .buttonStyle(.plain)
    .id(id)
    .onHover { isHovering in
      if isHovering {
        selectedResultID = id
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var orderedResults: [PaletteResult] { makeSnapshot().results }

  private func commandResultID(_ command: PaletteCommand) -> String {
    "command:\(command.id)"
  }

  private func draftResultID(_ draft: ArticleDraft) -> String {
    "draft:\(draft.id.uuidString)"
  }

  private func aiPromptResultID(_ prompt: AIPublishingQuickPrompt) -> String {
    "ai-prompt:\(prompt.rawValue)"
  }

  private func sectionResultID(_ section: WorkspaceSection) -> String {
    "section:\(section.rawValue)"
  }

  private func settingsResultID(_ item: SettingsSearchItem) -> String {
    "settings:\(item.id)"
  }

  private func synchronizeSelection() {
    let resultIDs = orderedResults.map(\.id)
    if let selectedResultID, resultIDs.contains(selectedResultID) {
      return
    }
    selectedResultID = resultIDs.first
  }

  private func moveSelection(by offset: Int) {
    let results = orderedResults
    guard !results.isEmpty else {
      selectedResultID = nil
      return
    }
    guard let selectedResultID,
      let currentIndex = results.firstIndex(where: { $0.id == selectedResultID })
    else {
      self.selectedResultID = results.first?.id
      return
    }
    let nextIndex = (currentIndex + offset + results.count) % results.count
    self.selectedResultID = results[nextIndex].id
  }

  private func performSelectedResult() {
    guard let selectedResultID,
      let result = orderedResults.first(where: { $0.id == selectedResultID })
    else {
      return
    }
    result.action()
  }

  private func localizedSectionTitle(_ section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  private func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
    dismiss()
  }

  private func openSection(_ section: WorkspaceSection) {
    store.selectSection(section)
    dismiss()
  }

  private var recentSettingsItemIDList: [String] {
    recentSettingsItemIDs.split(separator: ",").map(String.init)
  }

  private func openSettingsItem(_ item: SettingsSearchItem) {
    var recents = recentSettingsItemIDList.filter { $0 != item.id }
    recents.insert(item.id, at: 0)
    recentSettingsItemIDs = recents.prefix(12).joined(separator: ",")
    SettingsNavigation.present(
      destination: item.destination ?? .tab(item.tab),
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
    dismiss()
  }

  private var recentAIPromptIDList: [String] {
    recentAIPromptIDs
      .split(separator: ",")
      .map(String.init)
  }

  private func stablyRankedAIPrompts(
    _ prompts: [AIPublishingQuickPrompt]
  ) -> [AIPublishingQuickPrompt] {
    let unique = Dictionary(grouping: prompts, by: \.id)
      .compactMap(\.value.first)
    let recentOrder = Dictionary(
      uniqueKeysWithValues: recentAIPromptIDList.enumerated().map {
        ($0.element, $0.offset)
      }
    )
    return unique.sorted { lhs, rhs in
      let lhsRecent = recentOrder[lhs.rawValue] ?? Int.max
      let rhsRecent = recentOrder[rhs.rawValue] ?? Int.max
      if lhsRecent != rhsRecent {
        return lhsRecent < rhsRecent
      }
      let lhsPrimary = AIPublishingQuickPrompt.primaryPrompts.contains(lhs)
      let rhsPrimary = AIPublishingQuickPrompt.primaryPrompts.contains(rhs)
      if lhsPrimary != rhsPrimary {
        return lhsPrimary
      }
      return
        lhs.localizedDisplayName.localizedStandardCompare(rhs.localizedDisplayName)
        == .orderedAscending
    }
  }

  private func openAIPrompt(_ prompt: AIPublishingQuickPrompt) {
    var recents = recentAIPromptIDList.filter { $0 != prompt.rawValue }
    recents.insert(prompt.rawValue, at: 0)
    recentAIPromptIDs = recents.prefix(12).joined(separator: ",")
    _ = store.ai.openChatWorkspace(
      for: commandPresentation.selectedDraftID,
      quickPrompt: prompt
    )
    dismiss()
  }
}

private struct PaletteCommand: Identifiable {
  // Identity must survive localization changes and title/detail edits.
  let id: String
  let title: String
  let detail: String
  let systemImage: String
  var shortcut: String?
  let action: () -> Void

  init(
    id: String,
    title: String,
    detail: String,
    systemImage: String,
    shortcut: String? = nil,
    action: @escaping () -> Void
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.shortcut = shortcut
    self.action = action
  }
}

private struct PaletteSnapshot {
  let commands: [PaletteCommand]
  let aiPrompts: [AIPublishingQuickPrompt]
  let drafts: [ArticleDraft]
  let resourceSections: [WorkspaceSection]
  let rssSections: [WorkspaceSection]
  let workspaceSections: [WorkspaceSection]
  let settings: [SettingsSearchItem]
  let results: [PaletteResult]
}

private struct PaletteResult {
  let id: String
  let action: () -> Void
}
