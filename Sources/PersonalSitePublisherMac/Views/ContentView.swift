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
  enum Band: Equatable {
    case constrained
    case compactInspector
    case standardInspector
    case htmlSourceInspector
  }

  let band: Band

  static let initial = WorkspaceResponsiveLayoutSnapshot(
    width: WorkbenchLayoutMode.expandedWorkspaceWidth
  )

  init(width: CGFloat) {
    if width >= WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth {
      band = .htmlSourceInspector
    } else if WorkbenchLayoutMode.allowsInspector(width: width) {
      band = .standardInspector
    } else if WorkbenchLayoutMode.canManuallyRevealInspector(width: width) {
      band = .compactInspector
    } else {
      band = .constrained
    }
  }

  var isCompact: Bool {
    band == .constrained || band == .compactInspector
  }

  var allowsStandardInspector: Bool {
    band == .standardInspector || band == .htmlSourceInspector
  }

  var allowsHTMLSourceInspector: Bool { band == .htmlSourceInspector }
  var canManuallyRevealInspector: Bool { band == .compactInspector }
}

private struct WorkspaceResponsiveLayoutPreferenceKey: PreferenceKey {
  static let defaultValue = WorkspaceResponsiveLayoutSnapshot.initial

  static func reduce(
    value: inout WorkspaceResponsiveLayoutSnapshot,
    nextValue: () -> WorkspaceResponsiveLayoutSnapshot
  ) {
    value = nextValue()
  }
}

/// Keeps continuous window measurements in a leaf view. The preference value
/// compares by semantic layout band, so `ContentView` updates only at the
/// 960/1180/1240 point decisions instead of for every resize pixel.
private struct WorkspaceResponsiveLayoutReader: View {
  var body: some View {
    GeometryReader { geometry in
      Color.clear.preference(
        key: WorkspaceResponsiveLayoutPreferenceKey.self,
        value: WorkspaceResponsiveLayoutSnapshot(width: geometry.size.width)
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct WorkspaceResponsiveLayoutHost<Content: View>: View {
  let content: Content
  let onChange: (WorkspaceResponsiveLayoutSnapshot) -> Void

  init(
    onChange: @escaping (WorkspaceResponsiveLayoutSnapshot) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.onChange = onChange
  }

  var body: some View {
    content
      .background(WorkspaceResponsiveLayoutReader())
      .onPreferenceChange(WorkspaceResponsiveLayoutPreferenceKey.self, perform: onChange)
  }
}

struct ContentView: View {
  let store: WorkbenchStore
  let rssStore: RSSReaderStore
  @ObservedObject private var rootPresentation: WorkbenchRootPresentationFeatureFacade
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.controlActiveState) private var controlActiveState
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
  @SceneStorage("workspace.revealInspectorInCompactWriting") private
    var revealsInspectorInCompactWriting = false
  @SceneStorage("workspace.windowID") private var windowIDRawValue = ""
  @SceneStorage("workspace.selectedSection") private var selectedSectionRawValue = ""
  @SceneStorage("workspace.selectedDraftID") private var selectedDraftIDRawValue = ""
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
  // These reference models need stable window lifetime, but ContentView does
  // not read their published values. Feature leaves observe them directly.
  @State private var aiChatInspectorOperationSession = AIChatSurfaceOperationSession()
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var imageWorkbenchContextStage: ImageWorkbenchContextStage = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  @StateObject private var repositorySourceSession: RepositoryHTMLSourceSession
  @State private var localSitePreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @State private var sceneCommandRouter = WorkspaceSceneCommandRouter()
  @StateObject private var windowSession: WorkspaceWindowSession

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

  private var shellState: WorkbenchRootPresentationFeatureFacade { rootPresentation }
  private var presentationState: WorkbenchRootPresentationFeatureFacade { rootPresentation }

  init(store: WorkbenchStore, rssStore: RSSReaderStore) {
    self.store = store
    self.rssStore = rssStore
    _rootPresentation = ObservedObject(wrappedValue: store.rootPresentation)
    _repositorySourceSession = StateObject(wrappedValue: RepositoryHTMLSourceSession())
    _localSitePreviewState = State(
      initialValue: WorkbenchLocalSitePreviewFeatureFacade(store: store)
    )
    _windowSession = StateObject(
      wrappedValue: WorkspaceWindowSession(
        selectedSection: store.selectedSection,
        selectedDraftID: store.selectedDraftID
      )
    )
  }

  var body: some View {
    contentView
  }

  private var contentView: some View {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      let _ = ContentViewBodyPerformanceProbe.record()
    #endif
    return WorkspaceResponsiveLayoutHost(onChange: applyResponsiveLayout) {
      let compactLayout = isCompactLayout
      let isInspectorVisible = inspectorPresentation.wrappedValue
      let inspectorColumnWidths = WorkspaceInspectorColumnWidthPolicy.widths(
        isAIAssistantPresented: presentationState.isAssistantPresented
      )

      ZStack {
        WorkspaceShellSplitLayout(
          store: store,
          selectedSection: windowSession.selectedSection,
          selectedDraftID: windowSession.selectedDraftID,
          isCompact: compactLayout,
          isFocusMode: hidesWorkspaceSidebar,
          isInspectorPresented: isInspectorVisible,
          contentHealthFilter: $contentHealthFilter,
          imageWorkbenchContextStage: $imageWorkbenchContextStage,
          repositoryContextStage: $repositoryContextStage,
          repositorySourceSession: repositorySourceSession,
          rssStore: rssStore,
          onSelectSection: selectWorkspaceSection,
          onSelectDraft: selectWindowDraft,
          onFocusDraft: focusWindowDraft
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: inspectorPresentation) {
          MetadataColumn(
            store: store,
            selectedSection: windowSession.selectedSection,
            selectedDraftID: windowSession.selectedDraftID,
            rssStore: rssStore,
            repositoryContextStage: repositoryContextStage,
            repositorySourceSession: repositorySourceSession,
            aiChatSurfaceState: $aiChatInspectorSurfaceState,
            aiChatOperationSession: aiChatInspectorOperationSession,
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
              store: store
            )
            .zIndex(1)
          }
        #endif

        if shellState.isQuickHideActive {
          QuickHideOverlay(store: store)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .zIndex(2)
        }
      }
    }
    .background(WorkbenchAccessibilityStatusAnnouncer(store: store))
    .safeAreaInset(edge: .top, spacing: 0) {
      if store.isSafeMode {
        WorkbenchSafeModeBanner()
          .transition(.opacity.combined(with: .move(edge: .top)))
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
          selectedDraftID: windowSession.selectedDraftID,
          selectedSection: windowSession.selectedSection,
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
    .onAppear {
      restoreWindowSessionStorageIfNeeded()
      synchronizeWindowSessionActivity()
    }
    .onChange(of: sceneCommandRouterRootUpdateKey, initial: true) { _, _ in
      updateSceneCommandRouterRootActions()
    }
    .onDisappear {
      sceneCommandRouter.clearAll()
      _ = aiChatInspectorOperationSession.handle(
        .ownerTeardown,
        forwardingTo: { ownerToken in
          store.ai.cancelChatReply(expectedOwnerToken: ownerToken)
        }
      )
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
    .onChange(of: controlActiveState) { _, _ in
      synchronizeWindowSessionActivity()
    }
    .onChange(of: shellState.selectedSection) { _, section in
      windowSession.receiveSharedSection(section)
    }
    .onChange(of: shellState.selectedDraftID) { _, draftID in
      windowSession.receiveSharedDraft(draftID)
    }
    .onChange(of: windowSession.selectedSection) { _, section in
      selectedSectionRawValue = section.rawValue
      normalizeWorkspacePresentation(for: section)
      if section == .rss {
        refreshStaleRSSIfNeeded()
      }
    }
    .onChange(of: windowSession.selectedDraftID) { _, draftID in
      selectedDraftIDRawValue = draftID?.uuidString ?? ""
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

  private func restoreWindowSessionStorageIfNeeded() {
    let values = windowSession.restoreStorageIfNeeded(
      windowIDRawValue: windowIDRawValue,
      selectedSectionRawValue: selectedSectionRawValue,
      fallbackSection: shellState.selectedSection,
      selectedDraftIDRawValue: selectedDraftIDRawValue,
      fallbackDraftID: shellState.selectedDraftID
    )
    windowIDRawValue = values.windowIDRawValue
    selectedSectionRawValue = values.selectedSectionRawValue
    selectedDraftIDRawValue = values.selectedDraftIDRawValue
    normalizeWorkspacePresentation(for: windowSession.selectedSection)
  }

  private func synchronizeWindowSessionActivity() {
    windowSession.reconcileDraftSelection(
      validDraftIDs: Set(store.drafts.map(\.id)),
      fallbackDraftID: shellState.selectedDraftID
    )
    windowSession.setKeyWindow(controlActiveState == .key) { section, draftID in
      if store.selectedSection != section {
        store.selectSection(section)
      }
      let activatedDraftID = store.activateDraftSelectionContext(draftID)
      windowSession.receiveSharedDraft(activatedDraftID)
    }
  }

  private var sceneCommandRouterRootUpdateKey: WorkspaceSceneCommandRouter.RootUpdateKey {
    WorkspaceSceneCommandRouter.RootUpdateKey(
      selectedSection: windowSession.selectedSection,
      isFocusModeActive: effectiveFocusMode,
      canToggleFocusMode: shellState.canUseProtectedWorkbench
        && windowSession.selectedSection == .writing,
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
          && windowSession.selectedSection == .writing,
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
    guard
      RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
        isSceneActive: scenePhase == .active,
        isSafeMode: store.isSafeMode,
        isEnabled: isRSSBackgroundRefreshEnabled,
        isRSSSectionSelected: windowSession.selectedSection == .rss
      )
    else { return }
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
    guard activateCurrentWindowSharedContext() else { return }
    store.flushDraftBodyEditorBuffers()
    modalPresentation.present(.draftFullTextSearch)
  }

  private func openLocalSitePreview() {
    guard shellState.canUseProtectedWorkbench else { return }
    guard activateCurrentWindowSharedContext() else { return }
    selectWorkspaceSection(.sync)
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
    normalizeWorkspacePresentation(for: windowSession.selectedSection)
    if !store.isSafeMode {
      presentFirstRunSetupIfNeeded()
    }
  }

  private func refreshExternallyCreatedDrafts() {
    guard
      RepositoryDraftDiscoveryPolicy.shouldRunAutomatically(
        isSafeMode: store.isSafeMode,
        canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
        isEnabled: store.activeProfile.resolvedAutomaticallyImportsNewRepositoryArticles,
        isRefreshRunning: isRefreshingExternallyCreatedDrafts
      )
    else { return }
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
      selectWorkspaceSection(.sync)
      Task {
        await store.repository.scanAsync()
      }
    case .createNewSite:
      selectWorkspaceSection(.siteStarter)
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
      for: windowSession.selectedSection,
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

    _ = openAIAssistantWorkspace(for: windowSession.selectedDraftID)
  }

  @discardableResult
  private func openAIAssistantWorkspace(
    for draftID: UUID?,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    guard shellState.canUseProtectedWorkbench,
      prepareInspectorForUserRequest()
    else { return false }
    guard activateCurrentWindowSharedContext() else { return false }
    if effectiveFocusMode {
      isFocusMode = false
    }
    return store.ai.openChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  private var inspectorToolbarHelp: String {
    if canOverrideInspectorInCurrentLayout && !allowsInspectorInCurrentLayout {
      return String(localized: "窗口较窄；点击后会收起左侧栏并显示 Inspector")
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
    if canOverrideInspectorInCurrentLayout && !allowsInspectorInCurrentLayout {
      return String(localized: "窗口较窄，已临时隐藏；点击后会收起左侧栏并显示")
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
      revealsInspectorInCompactWriting = false
    }
    guard windowSession.isKeyWindow else { return }
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
    guard windowSession.selectedSection != section else { return }

    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if section != .writing {
        if windowSession.isKeyWindow {
          hideInspectorIfNeeded()
        }
      }
      windowSession.selectSection(section) { selectedSection in
        guard store.selectedSection != selectedSection else { return }
        store.selectSection(selectedSection)
      }
    }
  }

  private func selectWindowDraft(_ draftID: UUID?) {
    windowSession.selectDraft(draftID) { selectedDraftID in
      activateSharedContext(
        section: windowSession.selectedSection,
        draftID: selectedDraftID
      )
    }
  }

  private func focusWindowDraft(_ draftID: UUID, section: WorkspaceSection) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      windowSession.selectContext(
        section: section,
        draftID: draftID
      ) { selectedSection, selectedDraftID in
        activateSharedContext(
          section: selectedSection,
          draftID: selectedDraftID
        )
      }
    }
  }

  private func toggleArticleInspector() {
    let wasAllowed = allowsInspectorInCurrentLayout
    guard prepareInspectorForUserRequest() else { return }
    if effectiveFocusMode {
      isFocusMode = false
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

    if !wasAllowed && shellState.isInspectorPresented {
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
    guard activateCurrentWindowSharedContext() else { return }
    store.ensureEditableDraftSelected()
    windowSession.receiveSharedDraft(store.selectedDraftID)
    store.runPreflight()
    modalPresentation.present(.publishDrawer)
    store.setPublishActionMessage(
      message ?? String(localized: "发布流程已打开，请选择保存到本地或发布上线。"),
      status: .information
    )
  }

  @discardableResult
  private func activateCurrentWindowSharedContext() -> Bool {
    guard controlActiveState == .key else { return false }
    let activate: (WorkspaceSection, UUID?) -> Void = { section, draftID in
      activateSharedContext(section: section, draftID: draftID)
    }
    let wasKeyWindow = windowSession.isKeyWindow
    windowSession.setKeyWindow(true, activateSharedContext: activate)
    if wasKeyWindow {
      windowSession.activateSharedContext(activate)
    }
    return true
  }

  private func activateSharedContext(
    section: WorkspaceSection,
    draftID: UUID?
  ) {
    if store.selectedSection != section {
      store.selectSection(section)
    }
    let activatedDraftID = store.activateDraftSelectionContext(draftID)
    windowSession.receiveSharedDraft(activatedDraftID)
  }

  private var isCompactLayout: Bool {
    responsiveLayout.isCompact
  }

  private func applyResponsiveLayout(_ snapshot: WorkspaceResponsiveLayoutSnapshot) {
    guard snapshot != responsiveLayout else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      responsiveLayout = snapshot
      if !canOverrideInspector(snapshot) {
        revealsInspectorInCompactWriting = false
      }
    }
  }

  private var allowsInspectorInCurrentLayout: Bool {
    allowsInspectorByWidth
      || (canOverrideInspectorInCurrentLayout && revealsInspectorInCompactWriting)
  }

  private var allowsInspectorByWidth: Bool {
    if windowSession.selectedSection == .sync, repositoryContextStage == .source {
      return responsiveLayout.allowsHTMLSourceInspector
    }
    return responsiveLayout.allowsStandardInspector
  }

  private var canOverrideInspectorInCurrentLayout: Bool {
    canOverrideInspector(responsiveLayout)
  }

  private func canOverrideInspector(_ snapshot: WorkspaceResponsiveLayoutSnapshot) -> Bool {
    windowSession.selectedSection == .writing
      && snapshot.canManuallyRevealInspector
  }

  private var canRequestInspectorInCurrentLayout: Bool {
    allowsInspectorInCurrentLayout || canOverrideInspectorInCurrentLayout
  }

  private var effectiveFocusMode: Bool {
    isFocusMode
  }

  private var hidesWorkspaceSidebar: Bool {
    effectiveFocusMode
      || (revealsInspectorInCompactWriting
        && canOverrideInspectorInCurrentLayout
        && shellState.isInspectorPresented
        && supportsInspector)
  }

  @discardableResult
  private func prepareInspectorForUserRequest() -> Bool {
    if allowsInspectorInCurrentLayout {
      return true
    }
    guard canOverrideInspectorInCurrentLayout else {
      return false
    }
    revealsInspectorInCompactWriting = true
    return true
  }

  private func toggleFocusMode() {
    guard windowSession.selectedSection == .writing else { return }
    if isFocusMode {
      isFocusMode = false
    } else {
      isFocusMode = true
    }
  }
}

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private struct ScreenshotInlineAIInspector: View {
    let store: WorkbenchStore
    @State private var surfaceState = AIChatSurfaceState(surface: .inspector)
    @StateObject private var operationSession = AIChatSurfaceOperationSession()

    var body: some View {
      GeometryReader { geometry in
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Divider()
          AIChatContextInspectorView(
            store: store,
            surfaceState: $surfaceState,
            operationSession: operationSession
          )
          .frame(width: min(max(geometry.size.width * 0.38, 460), 520))
          .frame(maxHeight: .infinity)
          .background(Color(nsColor: .windowBackgroundColor))
        }
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
