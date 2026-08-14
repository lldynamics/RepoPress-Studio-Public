import AppKit
import OSLog
import PublishingWorkbenchCore
import SwiftUI

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private enum ContentViewBodyPerformanceProbe {
    private static let isEnabled =
      ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_CONTENT_VIEW_BODY_PROBE"] == "1"
    private static let signposter = OSSignposter(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "SwiftUIBody"
    )

    static func record() {
      guard isEnabled else { return }
      signposter.emitEvent("ContentView.body")
    }
  }
#endif

struct WorkspaceResponsiveLayoutSnapshot: Equatable {
  let width: CGFloat
  let editorDisplayMode: EditorDisplayMode

  static let initial = WorkspaceResponsiveLayoutSnapshot(
    width: WorkbenchLayoutMode.expandedWorkspaceWidth,
    editorDisplayMode: .edit
  )

  static func == (
    lhs: WorkspaceResponsiveLayoutSnapshot,
    rhs: WorkspaceResponsiveLayoutSnapshot
  ) -> Bool {
    lhs.layoutIdentity == rhs.layoutIdentity
  }

  private var layoutIdentity: LayoutIdentity {
    LayoutIdentity(
      editorDisplayMode: editorDisplayMode,
      isCompact: WorkbenchLayoutMode.isCompact(width: width),
      allowsStandardInspector: WorkbenchLayoutMode.allowsInspector(width: width),
      allowsEditorInspector: WorkbenchLayoutMode.allowsInspector(
        width: width,
        editorDisplayMode: editorDisplayMode
      ),
      allowsHTMLSourceInspector:
        width >= WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth,
      canOverrideSplitInspector:
        editorDisplayMode == .split
        && width >= WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
        && !WorkbenchLayoutMode.allowsInspector(
          width: width,
          editorDisplayMode: editorDisplayMode
        ),
      prefersFocusedWriting: WorkbenchLayoutMode.prefersFocusedWriting(
        width: width,
        editorDisplayMode: editorDisplayMode
      )
    )
  }

  private struct LayoutIdentity: Equatable {
    let editorDisplayMode: EditorDisplayMode
    let isCompact: Bool
    let allowsStandardInspector: Bool
    let allowsEditorInspector: Bool
    let allowsHTMLSourceInspector: Bool
    let canOverrideSplitInspector: Bool
    let prefersFocusedWriting: Bool
  }
}

struct ContentView: View {
  let store: WorkbenchStore
  let rssStore: RSSReaderStore
  @ObservedObject private var shellState: WorkbenchShellFeatureFacade
  @ObservedObject private var presentationState: WorkbenchContentPresentationFeatureFacade
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage(RSSReaderUserPreferences.backgroundRefreshEnabledKey)
  private var isRSSBackgroundRefreshEnabled =
    RSSReaderUserPreferences.defaultBackgroundRefreshEnabled
  @AppStorage(RSSReaderUserPreferences.backgroundRefreshIntervalMinutesKey)
  private var rssBackgroundRefreshIntervalMinutes =
    RSSReaderUserPreferences.defaultBackgroundRefreshIntervalMinutes
  @AppStorage("didCompleteFirstRunSetup") private var didCompleteFirstRunSetup = false
  @SceneStorage("workspace.focusMode") private var isFocusMode = false
  @SceneStorage("workspace.revealSidebarInNarrowSplit") private var revealsSidebarInNarrowSplit =
    false
  @SceneStorage("workspace.revealInspectorInNarrowSplit") private
    var revealsInspectorInNarrowSplit = false
  @State private var didApplyInitialWorkbenchPreferences = false
  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    @State private var didApplyScreenshotDemoSurface = false
  #endif
  @State private var isRefreshingExternallyCreatedDrafts = false
  @State private var isDraftRecoveryPresented = false
  @State private var modalPresentation = WorkspaceModalPresentationState()
  @State private var commandPaletteEditorCommands: MarkdownEditorCommandActions?
  @State private var responsiveLayout = WorkspaceResponsiveLayoutSnapshot.initial
  @State private var aiChatInspectorSurfaceState = AIChatSurfaceState(surface: .inspector)
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var imageWorkbenchContextStage: ImageWorkbenchContextStage = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  @StateObject private var repositorySourceSession: RepositoryHTMLSourceSession
  @StateObject private var rssPresentation: RSSReaderPresentationState
  @StateObject private var localSitePreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @StateObject private var sceneCommandRouter = WorkspaceSceneCommandRouter()

  private var repositoryAutoSyncTaskID: RepositoryAutoSyncTaskID {
    RepositoryAutoSyncTaskID(
      scenePhase: scenePhase,
      isSafeMode: store.isSafeMode
    )
  }

  private struct RepositoryAutoSyncTaskID: Equatable {
    let scenePhase: ScenePhase
    let isSafeMode: Bool
  }

  init(store: WorkbenchStore, rssStore: RSSReaderStore) {
    self.store = store
    self.rssStore = rssStore
    _shellState = ObservedObject(wrappedValue: store.shell)
    _presentationState = ObservedObject(wrappedValue: store.contentPresentation)
    _repositorySourceSession = StateObject(wrappedValue: RepositoryHTMLSourceSession())
    _rssPresentation = StateObject(wrappedValue: RSSReaderPresentationState())
    _localSitePreviewState = StateObject(
      wrappedValue: WorkbenchLocalSitePreviewFeatureFacade(store: store)
    )
  }

  var body: some View {
    contentView
  }

  private var contentView: some View {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      let _ = ContentViewBodyPerformanceProbe.record()
    #endif
    return GeometryReader { geometry in
      let compactLayout = WorkbenchLayoutMode.isCompact(width: geometry.size.width)
      let responsiveLayoutSnapshot = WorkspaceResponsiveLayoutSnapshot(
        width: geometry.size.width,
        editorDisplayMode: presentationState.editorDisplayMode
      )
      let isInspectorVisible = inspectorPresentation.wrappedValue
      let inspectorColumnWidths = WorkspaceInspectorColumnWidthPolicy.widths(
        isAIAssistantPresented: presentationState.isAssistantPresented
      )

      let workspace = ZStack {
        WorkspaceShellSplitLayout(
          store: store,
          isCompact: compactLayout,
          isFocusMode: effectiveFocusMode,
          workspaceWidth: geometry.size.width,
          isInspectorPresented: isInspectorVisible,
          contentHealthFilter: $contentHealthFilter,
          imageWorkbenchContextStage: $imageWorkbenchContextStage,
          repositoryContextStage: $repositoryContextStage,
          repositorySourceSession: repositorySourceSession,
          rssStore: rssStore,
          rssPresentation: rssPresentation,
          onSelectSection: selectWorkspaceSection
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: inspectorPresentation) {
          MetadataColumn(
            store: store,
            rssStore: rssStore,
            repositoryContextStage: repositoryContextStage,
            repositorySourceSession: repositorySourceSession,
            aiChatSurfaceState: $aiChatInspectorSurfaceState,
            prioritizesChecks: compactLayout
          )
          .inspectorColumnWidth(
            min: inspectorColumnWidths.minimum,
            ideal: inspectorColumnWidths.ideal,
            max: inspectorColumnWidths.maximum
          )
        }
        .disabled(shellState.isQuickHideActive)
        .accessibilityHidden(shellState.isQuickHideActive)

        #if DEBUG || SCREENSHOT_CAPTURE_BUILD
          if usesInlineAIScreenshotInspector {
            ScreenshotInlineAIInspector(
              store: store,
              width: min(max(geometry.size.width * 0.38, 460), 520)
            )
            .zIndex(1)
          }
        #endif

        if shellState.isQuickHideActive {
          QuickHideOverlay(store: store)
            .zIndex(2)
        }
      }
      // Geometry callbacks can run while AppKit is in the middle of a layout
      // pass. Defer the state publication so responsive layout changes cannot
      // feed back into the same pass.
      workspace
        .task(id: responsiveLayoutSnapshot) {
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
          applyResponsiveLayout(responsiveLayoutSnapshot)
        }
    }
    .background(WorkbenchAccessibilityStatusAnnouncer(store: store))
    .safeAreaInset(edge: .top, spacing: 0) {
      if store.isSafeMode {
        WorkbenchSafeModeBanner()
      }
    }
    .environment(
      \.publishDrawerCommandAction,
      PublishDrawerCommandAction { message in
        openPublishDrawer(message: message)
      }
    )
    .environment(
      \.localSitePreviewCommandAction,
      LocalSitePreviewCommandAction {
        openLocalSitePreview()
      }
    )
    .environment(
      \.aiChatWorkspaceCommandAction,
      AIChatWorkspaceCommandAction(
        isAvailable: shellState.canUseProtectedWorkbench
          && canRequestInspectorInCurrentLayout,
        unavailableReason: canRequestInspectorInCurrentLayout
          ? nil
          : String(localized: "扩大窗口后可使用 Inspector"),
        open: { draftID, quickPrompt in
          openAIAssistantWorkspace(for: draftID, quickPrompt: quickPrompt)
        }
      )
    )
    .environmentObject(localSitePreviewState)
    .environmentObject(sceneCommandRouter)
    .focusedSceneObject(sceneCommandRouter)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        WorkspaceToolbarNavigationContent(
          store: store,
          canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
          selectedDraftID: shellState.selectedDraftID,
          selectedSection: shellState.selectedSection,
          isCompact: isCompactLayout,
          isQuickHideActive: shellState.isQuickHideActive,
          openPublishFlow: { openPublishDrawer(message: nil) },
          openRepositoryOverview: {
            repositoryContextStage = .overview
            selectWorkspaceSection(.sync)
          },
          openContentHealthOverview: {
            contentHealthFilter = .overview
            selectWorkspaceSection(.contentHealth)
          },
          openReleaseHistory: {
            repositoryContextStage = .history
            selectWorkspaceSection(.sync)
          }
        )
        .accessibilityHidden(shellState.isQuickHideActive)
      }

      ToolbarItem(placement: .principal) {
        OmniCommandSearchBar(isCompact: isCompactLayout) {
          guard shellState.canUseProtectedWorkbench else { return }
          commandPaletteEditorCommands = sceneCommandRouter.markdownEditorCommandActions
          modalPresentation.present(.commandPalette)
        }
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Button(action: toggleAIAssistantWorkspace) {
          Label(String(localized: "AI 助手"), systemImage: "sparkles")
        }
        .buttonStyle(
          WorkspaceToolbarIconButtonStyle(isActive: isAIAssistantWorkspaceVisible)
        )
        .help(
          isAIAssistantWorkspaceVisible
            ? String(localized: "关闭 AI 对话")
            : String(localized: "在右侧继续当前文章的 AI 对话")
        )
        .accessibilityLabel(String(localized: "AI 助手"))
        .accessibilityValue(
          isAIAssistantWorkspaceVisible
            ? String(localized: "AI 助手已显示")
            : String(localized: "已隐藏")
        )
        .accessibilityIdentifier("ai-assistant-toolbar-button")
        .disabled(
          !shellState.canUseProtectedWorkbench
            || (!isAIAssistantWorkspaceVisible && !canRequestInspectorInCurrentLayout)
        )

        if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
          inspectorToolbarButton
        }
      }
    }
    .background(
      MainWindowInitialSizeBridge(
        sourceSession: repositorySourceSession,
        profileProvider: { store.activeProfile }
      )
    )
    .onChange(of: sceneCommandRouterRootUpdateKey, initial: true) { _, _ in
      updateSceneCommandRouterRootActions()
    }
    .onDisappear {
      sceneCommandRouter.clearAll()
    }
    .task {
      await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
      guard !Task.isCancelled else { return }
      handleContentViewAppear()
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(
        store.isSafeMode ? false : newValue
      )
    }
    .onChange(of: shellState.isQuickHideActive) { _, isActive in
      if isActive {
        modalPresentation.dismiss()
      } else if !store.isSafeMode {
        refreshExternallyCreatedDrafts()
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active, !store.isSafeMode else { return }
      refreshExternallyCreatedDrafts()
      refreshStaleRSSIfNeeded()
    }
    .onChange(of: shellState.selectedSection) { _, section in
      normalizeWorkspacePresentation(for: section)
      if section == .rss {
        refreshStaleRSSIfNeeded()
      }
    }
    .onChange(of: repositoryContextStage) { _, stage in
      if stage == .history {
        hideInspectorIfNeeded()
      }
    }
    .onChange(of: contentHealthFilter) { _, filter in
      if filter == .maintenance {
        hideInspectorIfNeeded()
      }
    }
    .task(id: repositoryAutoSyncTaskID) {
      await runRepositoryAutoSyncLoop()
    }
    .alert(
      String(localized: "工作台数据恢复"),
      isPresented: persistenceRecoveryAlertPresented,
      actions: persistenceRecoveryAlertActions,
      message: persistenceRecoveryAlertMessage
    )
    .sheet(isPresented: $isDraftRecoveryPresented, content: draftRecoveryPanel)
    .sheet(item: modalPresentationBinding, content: modalContent)
  }

  private func handleContentViewAppear() {
    applyWorkbenchPreferences()
    if !store.pendingDraftRecoveries.isEmpty {
      isDraftRecoveryPresented = true
    }
    registerRepositorySourceSession()
    refreshStaleRSSIfNeeded()
  }

  private var sceneCommandRouterRootUpdateKey: WorkspaceSceneCommandRouter.RootUpdateKey {
    WorkspaceSceneCommandRouter.RootUpdateKey(
      selectedSection: shellState.selectedSection,
      isFocusModeActive: effectiveFocusMode,
      canToggleFocusMode: shellState.canUseProtectedWorkbench
        && shellState.selectedSection == .writing,
      repositorySourceHasUnsavedChanges: repositorySourceSession.hasUnsavedChanges
    )
  }

  private func updateSceneCommandRouterRootActions() {
    let commandRouter = sceneCommandRouter
    sceneCommandRouter.updateRoot(
      publishDrawerCommandAction: PublishDrawerCommandAction { message in
        openPublishDrawer(message: message)
      },
      localSitePreviewCommandAction: LocalSitePreviewCommandAction {
        openLocalSitePreview()
      },
      workspaceCommandPaletteAction: WorkspaceCommandPaletteAction(
        open: { [weak commandRouter] in
          guard shellState.canUseProtectedWorkbench else { return }
          commandPaletteEditorCommands = commandRouter?.markdownEditorCommandActions
          modalPresentation.present(.commandPalette)
        },
        openMaintenance: openMaintenanceSubpage,
        openReleaseHistory: openReleaseHistorySubpage
      ),
      workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction {
        guard shellState.canUseProtectedWorkbench else { return }
        modalPresentation.present(.firstRunSetup)
      },
      draftFullTextSearchAction: DraftFullTextSearchAction(open: openDraftFullTextSearch),
      workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction(
        isActive: effectiveFocusMode,
        canToggle: shellState.canUseProtectedWorkbench
          && shellState.selectedSection == .writing,
        toggle: toggleFocusMode
      ),
      repositorySourceSessionCommandActions: RepositorySourceSessionCommandActions(
        hasUnsavedChanges: repositorySourceSession.hasUnsavedChanges,
        save: {
          repositorySourceSession.saveSynchronously(profile: store.activeProfile)
        },
        lastErrorMessage: { repositorySourceSession.errorMessage }
      )
    )
  }

  private func refreshStaleRSSIfNeeded() {
    guard RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
      isSceneActive: scenePhase == .active,
      isSafeMode: store.isSafeMode,
      isEnabled: isRSSBackgroundRefreshEnabled,
      isRSSSectionSelected: shellState.selectedSection == .rss
    ) else { return }
    let staleInterval = RSSReaderUserPreferences.backgroundRefreshIntervalSeconds(
      rssBackgroundRefreshIntervalMinutes
    )
    Task { @MainActor in
      await rssStore.refreshStaleFeeds(staleAfter: staleInterval)
    }
  }

  private var modalPresentationBinding: Binding<WorkspaceModalPresentation?> {
    Binding(
      get: { modalPresentation.presented },
      set: { modalPresentation.replace(with: $0) }
    )
  }

  private func draftRecoveryPanel() -> some View {
    DraftRecoveryPanel(store: store)
  }

  private var persistenceRecoveryAlertPresented: Binding<Bool> {
    Binding(
      get: { shellState.persistenceRecoveryMessage != nil },
      set: {
        if !$0 && !shellState.isPersistenceRecoveryWriteProtected {
          store.dismissPersistenceRecoveryMessage()
        }
      }
    )
  }

  @ViewBuilder
  private func persistenceRecoveryAlertActions() -> some View {
    if shellState.isPersistenceRecoveryWriteProtected {
      Button(String(localized: "恢复其他备份…")) {
        guard let sourceURL = WorkbenchRecoverySelectionPanel.chooseSnapshot() else { return }
        if store.installPersistenceRecoverySnapshot(from: sourceURL) {
          NSApp.terminate(nil)
        }
      }
      Button(String(localized: "导出故障文件…")) {
        guard let directoryURL = WorkbenchRecoverySelectionPanel.chooseExportDirectory() else {
          return
        }
        _ = store.exportPersistenceRecoveryFiles(to: directoryURL)
      }
      Button(String(localized: "重置为空白工作台"), role: .destructive) {
        _ = store.resetPersistenceAfterUnrecoverableSnapshot()
      }
    } else {
      Button(String(localized: "继续")) {
        store.dismissPersistenceRecoveryMessage()
      }
    }
  }

  private func persistenceRecoveryAlertMessage() -> some View {
    Text(persistenceRecoveryMessage)
  }

  private func modalIsPresentedBinding(
    _ presentation: WorkspaceModalPresentation
  ) -> Binding<Bool> {
    Binding(
      get: { modalPresentation.presented == presentation },
      set: { isPresented in
        if isPresented {
          modalPresentation.present(presentation)
        } else {
          modalPresentation.dismiss(presentation)
        }
      }
    )
  }

  @ViewBuilder
  private func modalContent(_ presentation: WorkspaceModalPresentation) -> some View {
    WorkbenchModalSurface {
      modalContentBody(presentation)
    }
  }

  @ViewBuilder
  private func modalContentBody(_ presentation: WorkspaceModalPresentation) -> some View {
    switch presentation {
    case .publishDrawer:
      PublishDrawerView(
        publishingFacade: store.publishing,
        store: store,
        isPresented: modalIsPresentedBinding(.publishDrawer)
      )
      .frame(minWidth: 680, idealWidth: 780, minHeight: 600, idealHeight: 720)
    case .localSitePreview:
      LocalSitePreviewPanelView()
    case .firstRunSetup:
      FirstRunSetupView(
        store: store,
        finish: finishFirstRunSetup,
        skip: skipFirstRunSetup
      )
    case .commandPalette:
      WorkspaceCommandPalette(
        store: store,
        editorCommands: commandPaletteEditorCommands,
        onToggleFocusMode: toggleFocusMode
      )
    case .draftFullTextSearch:
      DraftFullTextSearchPanel(store: store)
    }
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    private var usesInlineAIScreenshotInspector: Bool {
      ScreenshotDemoDataService.isEnabledFromEnvironment
        && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .aiChat
    }
  #endif

  private func runRepositoryAutoSyncLoop() async {
    guard scenePhase == .active, !store.isSafeMode else { return }

    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        return
      }

      guard !Task.isCancelled, scenePhase == .active, !store.isSafeMode else {
        return
      }
      await store.tickRepositoryAndDeploymentPolling(now: Date())
    }
  }

  private func openDraftFullTextSearch() {
    guard shellState.canUseProtectedWorkbench else { return }
    store.flushDraftBodyEditorBuffers()
    modalPresentation.present(.draftFullTextSearch)
  }

  private func openLocalSitePreview() {
    guard shellState.canUseProtectedWorkbench else { return }
    store.selectSection(.sync)
    if !store.localSitePreviewRuntimeStatus.isRunning {
      store.startLocalSitePreview()
    }
    modalPresentation.present(.localSitePreview)
  }

  private func applyWorkbenchPreferences() {
    if !didApplyInitialWorkbenchPreferences {
      // AI is an explicit writing tool; a previous session must not reclaim the Inspector on launch.
      presentationState.hideAssistant()
      if scanRepositoryOnLaunch, !store.isSafeMode {
        Task {
          await store.repository.scanAsync()
        }
      }
      if !store.isSafeMode {
        refreshExternallyCreatedDrafts()
      }
      didApplyInitialWorkbenchPreferences = true
    }
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      applyScreenshotRequestedSubpageIfNeeded()
    #endif
    store.setAutomaticallyRefreshPreflightOnEdit(
      store.isSafeMode ? false : autoRunPreflight
    )
    normalizeWorkspacePresentation(for: shellState.selectedSection)
    if !store.isSafeMode {
      presentFirstRunSetupIfNeeded()
    }
  }

  private func refreshExternallyCreatedDrafts() {
    guard RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
      isSafeMode: store.isSafeMode,
      canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
      isEnabled: store.activeProfile.resolvedAutomaticallyImportsNewRepositoryArticles,
      isRefreshRunning: isRefreshingExternallyCreatedDrafts
    ) else { return }
    isRefreshingExternallyCreatedDrafts = true
    Task { @MainActor in
      defer { isRefreshingExternallyCreatedDrafts = false }
      _ = await store.importMissingDraftsFromLocalRepository()
    }
  }

  private func registerRepositorySourceSession() {
    RepositoryHTMLSourceSessionRegistry.shared.register(
      session: repositorySourceSession,
      profileProvider: { store.activeProfile }
    )
  }

  private func presentFirstRunSetupIfNeeded() {
    guard !store.isSafeMode else { return }
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      let isScreenshotDemo = ScreenshotDemoDataService.isEnabledFromEnvironment
    #else
      let isScreenshotDemo = false
    #endif
    if !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      didCompleteFirstRunSetup = true
    }
    guard
      WorkbenchFirstRunSetupPolicy.shouldPresent(
        didCompleteSetup: didCompleteFirstRunSetup,
        profile: store.activeProfile,
        isScreenshotDemo: isScreenshotDemo
      )
    else { return }
    modalPresentation.present(.firstRunSetup)
  }

  private func finishFirstRunSetup(_ path: FirstRunSetupPath) {
    didCompleteFirstRunSetup = true
    modalPresentation.dismiss(.firstRunSetup)

    switch path {
    case .connectExistingRepository:
      store.selectSection(.sync)
      Task {
        await store.repository.scanAsync()
      }
    case .createNewSite:
      store.selectSection(.siteStarter)
    case .localDrafts:
      store.prepareLocalDraftWorkspace()
    }
  }

  private func skipFirstRunSetup() {
    modalPresentation.dismiss(.firstRunSetup)
  }

  private var persistenceRecoveryMessage: String {
    shellState.persistenceRecoveryMessage ?? ""
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(
      for: shellState.selectedSection,
      isAIAssistantPresented: presentationState.isAssistantPresented,
      isRepositoryHistoryPresented: repositoryContextStage == .history,
      isMaintenancePresented: contentHealthFilter == .maintenance
    )
  }

  private var inspectorToolbarButton: some View {
    Button(action: toggleArticleInspector) {
      Label(String(localized: "Inspector"), systemImage: "sidebar.right")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: inspectorPresentation.wrappedValue
          && !presentationState.isAssistantPresented
      )
    )
    .disabled(!shellState.canUseProtectedWorkbench || !canRequestInspectorInCurrentLayout)
    .help(inspectorToolbarHelp)
    .accessibilityLabel(String(localized: "工作区 Inspector"))
    .accessibilityValue(inspectorAccessibilityValue)
    .accessibilityIdentifier("workspace-inspector-toggle")
  }

  private var isAIAssistantWorkspaceVisible: Bool {
    presentationState.isAssistantPresented && inspectorPresentation.wrappedValue
  }

  private func toggleAIAssistantWorkspace() {
    if isAIAssistantWorkspaceVisible {
      guard !store.ai.isChatRunning else {
        store.ai.setChatMessage(String(localized: "请先停止当前 AI 回复，再关闭 AI 助手。"))
        return
      }
      store.ai.closeAssistantPanel()
      return
    }

    _ = openAIAssistantWorkspace(for: shellState.selectedDraftID)
  }

  @discardableResult
  private func openAIAssistantWorkspace(
    for draftID: UUID?,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    guard shellState.canUseProtectedWorkbench,
      prepareInspectorForUserRequest()
    else { return false }
    if effectiveFocusMode {
      isFocusMode = false
      revealsSidebarInNarrowSplit = true
    }
    return store.ai.openChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  private var inspectorToolbarHelp: String {
    if canOverrideSplitInspector && !allowsInspectorInCurrentLayout {
      return String(localized: "分屏空间较窄；点击仍显示 Inspector")
    }
    guard allowsInspectorInCurrentLayout else {
      return String(localized: "扩大窗口后可使用 Inspector")
    }
    if presentationState.isAssistantPresented {
      return String(localized: "切换到文章 Inspector")
    }
    return inspectorPresentation.wrappedValue
      ? String(localized: "隐藏 Inspector")
      : String(localized: "显示 Inspector")
  }

  private var inspectorAccessibilityValue: String {
    if canOverrideSplitInspector && !allowsInspectorInCurrentLayout {
      return String(localized: "分屏空间较窄，已临时隐藏；可以手动显示")
    }
    guard allowsInspectorInCurrentLayout else {
      return String(localized: "窗口过窄，已临时隐藏")
    }
    if presentationState.isAssistantPresented {
      return String(localized: "AI 助手已显示")
    }
    return inspectorPresentation.wrappedValue
      ? String(localized: "已显示")
      : String(localized: "已隐藏")
  }

  private var inspectorPresentation: Binding<Bool> {
    Binding(
      get: {
        WorkspaceInspectorPresentation.isPresented(
          requested: shellState.isInspectorPresented,
          supportsInspector: supportsInspector,
          isFocusMode: effectiveFocusMode,
          allowsInspector: allowsInspectorInCurrentLayout
        )
      },
      set: { isPresented in
        guard allowsInspectorInCurrentLayout else { return }
        store.setInspectorPresented(isPresented)
        if !isPresented && presentationState.isAssistantPresented {
          presentationState.hideAssistant()
        }
      }
    )
  }

  private func normalizeWorkspacePresentation(for section: WorkspaceSection) {
    if section != .writing {
      isFocusMode = false
      revealsSidebarInNarrowSplit = false
      revealsInspectorInNarrowSplit = false
    }
    if section != .writing && presentationState.isAssistantPresented {
      presentationState.hideAssistant()
    }

    switch section {
    case .siteStarter:
      break
    case .sync, .images, .contentHealth, .rss:
      hideInspectorIfNeeded()
    case .writing, .library:
      break
    }
  }

  private func openMaintenanceSubpage() {
    contentHealthFilter = .maintenance
    selectWorkspaceSection(.contentHealth)
  }

  private func openReleaseHistorySubpage() {
    repositoryContextStage = .history
    selectWorkspaceSection(.sync)
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    private func applyScreenshotRequestedSubpageIfNeeded() {
      guard !didApplyScreenshotDemoSurface else { return }
      didApplyScreenshotDemoSurface = true
      switch ScreenshotDemoDataService.requestedSurfaceFromEnvironment {
      case .some(.deploymentStatus):
        repositoryContextStage = .history
      case .some(.maintenance):
        contentHealthFilter = .maintenance
      default:
        break
      }
    }
  #endif

  private func selectWorkspaceSection(_ section: WorkspaceSection) {
    guard shellState.selectedSection != section else { return }

    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if section != .writing {
        hideInspectorIfNeeded()
      }
      store.selectSection(section)
    }
  }

  private func toggleArticleInspector() {
    guard prepareInspectorForUserRequest() else { return }
    if effectiveFocusMode {
      isFocusMode = false
      revealsSidebarInNarrowSplit = true
      if presentationState.isAssistantPresented {
        presentationState.hideAssistant()
      }
      if !shellState.isInspectorPresented {
        store.setInspectorPresented(true)
      }
      return
    }

    if presentationState.isAssistantPresented {
      presentationState.hideAssistant()
      if !shellState.isInspectorPresented {
        store.setInspectorPresented(true)
      }
      return
    }

    store.setInspectorPresented(!shellState.isInspectorPresented)
  }

  private func hideInspectorIfNeeded() {
    if presentationState.isAssistantPresented {
      presentationState.hideAssistant()
    }
    if shellState.isInspectorPresented {
      store.setInspectorPresented(false)
    }
  }

  private func openPublishDrawer(message: String?) {
    store.ensureEditableDraftSelected()
    store.runPreflight()
    modalPresentation.present(.publishDrawer)
    store.setPublishActionMessage(
      message ?? String(localized: "发布流程已打开，请选择保存到本地或发布上线。"),
      status: .information
    )
  }

  private var isCompactLayout: Bool {
    WorkbenchLayoutMode.isCompact(width: responsiveLayout.width)
  }

  private func applyResponsiveLayout(_ snapshot: WorkspaceResponsiveLayoutSnapshot) {
    guard snapshot != responsiveLayout else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      responsiveLayout = snapshot
      if !automaticallyHidesSidebarForSplit(snapshot) {
        revealsSidebarInNarrowSplit = false
      }
      if !canOverrideSplitInspector(snapshot) {
        revealsInspectorInNarrowSplit = false
      }
    }
  }

  private var allowsInspectorInCurrentLayout: Bool {
    allowsInspectorByWidth || (canOverrideSplitInspector && revealsInspectorInNarrowSplit)
  }

  private var allowsInspectorByWidth: Bool {
    if shellState.selectedSection == .sync, repositoryContextStage == .source {
      return responsiveLayout.width >= WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth
    }
    return WorkbenchLayoutMode.allowsInspector(
      width: responsiveLayout.width,
      editorDisplayMode: shellState.selectedSection == .writing
        ? responsiveLayout.editorDisplayMode
        : nil
    )
  }

  private var canOverrideSplitInspector: Bool {
    canOverrideSplitInspector(responsiveLayout)
  }

  private func canOverrideSplitInspector(_ snapshot: WorkspaceResponsiveLayoutSnapshot) -> Bool {
    shellState.selectedSection == .writing
      && snapshot.editorDisplayMode == .split
      && snapshot.width >= WorkbenchLayoutMode.minimumInspectorWorkspaceWidth
      && !WorkbenchLayoutMode.allowsInspector(
        width: snapshot.width,
        editorDisplayMode: snapshot.editorDisplayMode
      )
  }

  private var canRequestInspectorInCurrentLayout: Bool {
    allowsInspectorInCurrentLayout || canOverrideSplitInspector
  }

  private var automaticallyHidesSidebarForSplit: Bool {
    automaticallyHidesSidebarForSplit(responsiveLayout)
  }

  private func automaticallyHidesSidebarForSplit(_ snapshot: WorkspaceResponsiveLayoutSnapshot)
    -> Bool
  {
    shellState.selectedSection == .writing
      && WorkbenchLayoutMode.prefersFocusedWriting(
        width: snapshot.width,
        editorDisplayMode: snapshot.editorDisplayMode
      )
  }

  private var effectiveFocusMode: Bool {
    isFocusMode || (automaticallyHidesSidebarForSplit && !revealsSidebarInNarrowSplit)
  }

  @discardableResult
  private func prepareInspectorForUserRequest() -> Bool {
    if allowsInspectorInCurrentLayout {
      return true
    }
    guard canOverrideSplitInspector else {
      return false
    }
    revealsInspectorInNarrowSplit = true
    return true
  }

  private func toggleFocusMode() {
    guard shellState.selectedSection == .writing else { return }
    if isFocusMode {
      isFocusMode = false
    } else if automaticallyHidesSidebarForSplit && !revealsSidebarInNarrowSplit {
      revealsSidebarInNarrowSplit = true
    } else {
      isFocusMode = true
    }
  }
}

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private struct ScreenshotInlineAIInspector: View {
    let store: WorkbenchStore
    let width: CGFloat
    @State private var surfaceState = AIChatSurfaceState(surface: .inspector)

    var body: some View {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        Divider()
        AIChatContextInspectorView(
          store: store,
          surfaceState: $surfaceState
        )
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
      }
    }
  }
#endif

private struct WorkbenchAccessibilityStatusAnnouncer: View {
  @ObservedObject private var activityStatus: WorkbenchActivityStatusFacade
  @State private var announcedStatus: WorkbenchAccessibilityStatus?

  init(store: WorkbenchStore) {
    _activityStatus = ObservedObject(wrappedValue: store.activityStatus)
  }

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .allowsHitTesting(false)
      .onAppear {
        announcedStatus = status
      }
      .onChange(of: status) { _, updatedStatus in
        guard announcedStatus != updatedStatus else { return }
        announcedStatus = updatedStatus
        guard updatedStatus.shouldAnnounce else { return }
        guard let application = NSApp else { return }
        NSAccessibility.post(
          element: application,
          notification: .announcementRequested,
          userInfo: [
            .announcement: updatedStatus.message,
            .priority: NSAccessibilityPriorityLevel.low.rawValue,
          ]
        )
      }
  }

  private var status: WorkbenchAccessibilityStatus {
    if activityStatus.isQuickHideActive { return .quickHideActive }
    if activityStatus.repositoryScanState.isScanning {
      return .repositoryScanning(activityStatus.repositoryScanState.message)
    }
    if activityStatus.isRemoteRepositoryPublishing { return .remotePublishing }
    if activityStatus.isAIChatRunning { return .aiReplying }
    if activityStatus.isDeploymentStatusChecking { return .deploymentChecking }
    if let error = activityStatus.lastSaveError?.nilIfEmpty { return .saveFailed(error) }
    return .saveStatus(activityStatus.lastSaveStatus)
  }
}

private enum WorkbenchAccessibilityStatus: Equatable {
  case quickHideActive
  case repositoryScanning(String)
  case remotePublishing
  case aiReplying
  case deploymentChecking
  case saveFailed(String)
  case saveStatus(String)

  var shouldAnnounce: Bool {
    switch self {
    case .saveStatus:
      return false
    default:
      return true
    }
  }

  var message: String {
    switch self {
    case .quickHideActive: return String(localized: "快速隐藏已启用（仅界面遮挡）。")
    case .repositoryScanning(let message):
      return String(format: String(localized: "仓库状态更新：%@"), message)
    case .remotePublishing: return String(localized: "正在执行线上发布。")
    case .aiReplying: return String(localized: "AI 正在回复。")
    case .deploymentChecking: return String(localized: "正在检查部署状态。")
    case .saveFailed(let error):
      return String(format: String(localized: "保存失败：%@"), error)
    case .saveStatus(let status):
      return String(format: String(localized: "保存状态：%@"), status)
    }
  }
}
