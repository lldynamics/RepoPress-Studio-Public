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

  func canManuallyRevealInspector(for section: WorkspaceSection) -> Bool {
    canManuallyRevealInspector && [.writing, .library, .rss].contains(section)
  }
}

struct PersistenceRecoveryResetFeedback: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  static func success(archiveURL: URL) -> Self {
    Self(
      title: String(localized: "已重置为空白工作台"),
      message: String(
        format: String(localized: "故障数据已归档到：%@"),
        archiveURL.path
      )
    )
  }

  static func failure(message: String) -> Self {
    Self(
      title: String(localized: "未能重置工作台"),
      message: message
    )
  }
}

/// A single value keeps the inspector's min/ideal/max constraints coherent while
/// moving between article and AI collaboration surfaces.
struct WorkspaceInspectorWidthState: Equatable {
  let constraints: WorkspaceInspectorColumnWidths
  let preferredWidth: CGFloat

  init(isAIAssistantPresented: Bool) {
    constraints = WorkspaceInspectorColumnWidthPolicy.widths(
      isAIAssistantPresented: isAIAssistantPresented
    )
    preferredWidth =
      isAIAssistantPresented
      ? constraints.ideal
      : constraints.minimum
  }
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
  @EnvironmentObject private var launchCoordinator: WorkbenchLaunchCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
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
  @SceneStorage("workspace.sidebarPresented") private var isSidebarPresented = true
  @SceneStorage("workspace.revealInspectorInCompactWriting") private
    var revealsInspectorInCompactWorkspace = false
  @SceneStorage("workspace.windowID") private var windowIDRawValue = ""
  @SceneStorage("workspace.selectedSection") private var selectedSectionRawValue = ""
  @SceneStorage("workspace.selectedDraftID") private var selectedDraftIDRawValue = ""
  @State private var didApplyInitialWorkbenchPreferences = false
  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    @State private var didApplyScreenshotDemoSurface = false
  #endif
  @State private var isDraftRecoveryPresented = false
  @State private var isPersistenceResetConfirmationPresented = false
  @State private var persistenceResetFeedback: PersistenceRecoveryResetFeedback?
  @State private var modalPresentation = WorkspaceModalPresentationState()
  @State private var isSettingsWorkspacePresented = false
  @State private var settingsWorkspaceDestination: SettingsDestination?
  @State private var settingsWorkspaceNavigationRequestID = UUID()
  @State private var commandPaletteEditorCommands: MarkdownEditorCommandActions?
  @State private var responsiveLayout = WorkspaceResponsiveLayoutSnapshot.initial
  @State private var repositoryContentMonitorClientID = UUID()
  @State private var operationalPollingClientID = UUID()
  @State private var aiChatInspectorSurfaceState = AIChatSurfaceState(surface: .inspector)
  // These reference models need stable window lifetime, but ContentView does
  // not read their published values. Feature leaves observe them directly.
  @State private var aiChatInspectorOperationSession = AIChatSurfaceOperationSession()
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var imageWorkbenchContextStage: ImageWorkbenchContextStage = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  @State private var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @State private var knowledgeInspectorPresentation = KnowledgeLibraryInspectorPresentationState()
  @StateObject private var repositorySourceSession: RepositoryHTMLSourceSession
  @State private var localSitePreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @StateObject private var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  @StateObject private var repositoryContentChangeMonitor: RepositoryContentChangeMonitorCoordinator
  @State private var sceneCommandRouter = WorkspaceSceneCommandRouter()
  @StateObject private var windowSession: WorkspaceWindowSession
  @State private var inspectorWidthState = WorkspaceInspectorWidthState(
    isAIAssistantPresented: false
  )
  @State private var inspectorWidthResetGeneration = 0

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
    _externalBrowserPreviewCoordinator = StateObject(
      wrappedValue: ExternalBrowserPreviewCoordinator(store: store)
    )
    _repositoryContentChangeMonitor = StateObject(
      wrappedValue: RepositoryContentChangeMonitorCoordinator.shared(store: store)
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
    return workspaceLifecycleContent
  }

  /// The responsive root remains independent from its modifier chains so the
  /// compiler does not have to infer the full scene, toolbar, and lifecycle
  /// expression as one nested generic type.
  private var workspaceRootContent: some View {
    return WorkspaceResponsiveLayoutHost(onChange: applyResponsiveLayout) {
      let compactLayout = isCompactLayout
      let isInspectorVisible = inspectorPresentation.wrappedValue
      let inspectorColumnWidthState = inspectorWidthState

      ZStack {
        if isSettingsWorkspacePresented {
          SettingsView(
            store: store,
            rssStore: rssStore,
            launchCoordinator: launchCoordinator,
            closeWorkspace: closeSettingsWorkspace,
            workspaceDestination: settingsWorkspaceDestination,
            workspaceNavigationRequestID: settingsWorkspaceNavigationRequestID
          )
          .disabled(shellState.isQuickHideActive)
          .accessibilityHidden(shellState.isQuickHideActive)
          .zIndex(1)
        } else {
          workspaceCenterLayout(
            compactLayout: compactLayout,
            isInspectorVisible: isInspectorVisible,
            inspectorColumnWidthState: inspectorColumnWidthState
          )

          if isPublishDrawerPresented {
            WorkspacePublishDrawerOverlay(
              publishingFacade: store.publishing,
              store: store,
              isPresented: modalIsPresentedBinding(.publishDrawer)
            )
            .transition(
              WorkbenchMotion.drawerTransition(reduceMotion: accessibilityReduceMotion)
            )
            .zIndex(2)
          }

          #if DEBUG || SCREENSHOT_CAPTURE_BUILD
            if usesInlineAIScreenshotInspector {
              ScreenshotInlineAIInspector(
                store: store
              )
              .zIndex(1)
            }
          #endif
        }

        quickHideOverlay
      }
    }
  }

  /// Keep environment injection and native toolbar construction together:
  /// their relative order is part of the scene contract, but neither needs to
  /// participate in lifecycle modifier type inference.
  private var workspaceToolbarAndEnvironmentContent: some View {
    workspaceRootContent
    .environment(
      \.settingsWorkspaceCommandAction,
      settingsWorkspaceCommandAction
    )
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
    .externalBrowserPreviewPresentation(coordinator: externalBrowserPreviewCoordinator)
    .toolbar {
      workspaceNavigationToolbar

      if isSettingsWorkspacePresented {
        ToolbarItem(placement: .principal) {
          Text("设置")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        }
      } else {
        // A principal ToolbarItem is an independent native host for the
        // composed search button. Keeping it inside the navigation group lets
        // AppKit omit the whole HStack from the toolbar AX tree.
        ToolbarItem(placement: .principal) {
          commandSearchToolbarButton
            .accessibilityHidden(shellState.isQuickHideActive)
        }
      }

      workspacePrimaryActionToolbar
    }
    .onChange(of: localSitePreviewState.activeProfileID) {
      externalBrowserPreviewCoordinator.cancelPendingOpen()
    }
    .onChange(of: windowSession.selectedDraftID) { _, draftID in
      externalBrowserPreviewCoordinator.cancelPendingOpen(ifDraftIsNoLongerCurrent: draftID)
    }
    .background(
      MainWindowInitialSizeBridge(
        sourceSession: repositorySourceSession,
        profileProvider: { store.activeProfile }
      )
    )
  }

  /// Lifecycle, state synchronization, and sheet presentation are deliberately
  /// a second type-check boundary after the native toolbar chain.
  private var workspaceLifecycleContent: some View {
    workspaceToolbarAndEnvironmentContent
    .onAppear {
      restoreWindowSessionStorageIfNeeded()
      synchronizeWindowSessionActivity()
      configureRepositoryContentChangeMonitor()
      configureOperationalPolling()
    }
    .onChange(of: sceneCommandRouterRootUpdateKey, initial: true) { _, _ in
      updateSceneCommandRouterRootActions()
    }
    .onDisappear(perform: handleContentViewDisappear)
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
      }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
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
      handleSelectedSectionChange(section: section)
    }
    .onChange(of: windowSession.selectedDraftID) { _, draftID in
      handleSelectedDraftIDChange(draftID: draftID)
    }
    .onChange(of: repositoryContextStage) { _, stage in
      handleRepositoryContextStageChange(stage: stage)
    }
    .onChange(of: contentHealthFilter) { _, filter in
      handleContentHealthFilterChange(filter: filter)
    }
    .onChange(of: presentationState.isAssistantPresented) { _, isAssistant in
      handleAssistantPresentationChange(isAssistant: isAssistant)
    }
    .alert(
      String(localized: "工作台数据恢复"),
      isPresented: persistenceRecoveryAlertPresented,
      actions: persistenceRecoveryAlertActions,
      message: persistenceRecoveryAlertMessage
    )
    .confirmationDialog(
      String(localized: "重置为空白工作台？"),
      isPresented: $isPersistenceResetConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(String(localized: "归档后重置"), role: .destructive) {
        resetPersistenceAfterConfirmation()
      }
      Button(String(localized: "取消"), role: .cancel) {}
    } message: {
      Text("这会归档当前无法读取的数据文件，然后保存一个空白工作台。请先导出故障文件或恢复其他备份；此操作不能自动还原旧工作台。")
    }
    .alert(item: $persistenceResetFeedback) { feedback in
      Alert(
        title: Text(feedback.title),
        message: Text(feedback.message),
        dismissButton: .default(Text("好"))
      )
    }
    .sheet(isPresented: $isDraftRecoveryPresented, content: draftRecoveryPanel)
    .sheet(item: sheetModalPresentationBinding, content: modalContent)
    .knowledgeLibraryInspectorSheets(
      knowledge: store.knowledge,
      presentation: $knowledgeInspectorPresentation
    )
  }

  private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
    guard newPhase == .active else {
      repositoryContentChangeMonitor.stop(clientID: repositoryContentMonitorClientID)
      store.stopOperationalPolling(clientID: operationalPollingClientID)
      return
    }
    guard oldPhase != .active, !store.isSafeMode else { return }
    configureRepositoryContentChangeMonitor()
    refreshExternallyCreatedDrafts()
    configureOperationalPolling()
    refreshStaleRSSIfNeeded()
  }

  private func handleContentViewDisappear() {
    repositoryContentChangeMonitor.stop(clientID: repositoryContentMonitorClientID)
    store.stopOperationalPolling(clientID: operationalPollingClientID)
    externalBrowserPreviewCoordinator.cancelPendingOpen()
    sceneCommandRouter.clearAll()

    let cancelChatReply: (UUID) -> Void = { ownerToken in
      store.ai.cancelChatReply(expectedOwnerToken: ownerToken)
    }
    _ = aiChatInspectorOperationSession.handle(
      .ownerTeardown,
      forwardingTo: cancelChatReply
    )
  }

  private func handleSelectedSectionChange(section: WorkspaceSection) {
    selectedSectionRawValue = section.rawValue
    normalizeWorkspacePresentation(for: section)
    if section != .library {
      knowledgeInspectorPresentation.dismissAll()
    }
    if section == .rss {
      refreshStaleRSSIfNeeded()
    }
  }

  private func handleSelectedDraftIDChange(draftID: UUID?) {
    selectedDraftIDRawValue = draftID?.uuidString ?? ""
  }

  private func handleRepositoryContextStageChange(stage: RepositoryContextStage) {
    if stage == .history {
      hideInspectorIfNeeded()
    }
  }

  private func handleContentHealthFilterChange(filter: ContentHealthContextFilter) {
    if filter == .maintenance {
      hideInspectorIfNeeded()
    }
  }

  private func handleAssistantPresentationChange(isAssistant: Bool) {
    updateInspectorWidthState(isAIAssistantPresented: isAssistant)
  }

  @ViewBuilder
  private func workspaceCenterLayout(
    compactLayout: Bool,
    isInspectorVisible: Bool,
    inspectorColumnWidthState: WorkspaceInspectorWidthState
  ) -> some View {
    WorkspaceShellSplitLayout(
      store: store,
      selectedSection: windowSession.selectedSection,
      selectedDraftID: windowSession.selectedDraftID,
      isCompact: compactLayout,
      isFocusMode: effectiveFocusMode,
      isInspectorPresented: isInspectorVisible,
      contentHealthFilter: $contentHealthFilter,
      imageWorkbenchContextStage: $imageWorkbenchContextStage,
      repositoryContextStage: $repositoryContextStage,
      repositoryChangedFileSelection: $repositoryChangedFileSelection,
      knowledgeInspectorPresentation: $knowledgeInspectorPresentation,
      repositorySourceSession: repositorySourceSession,
      rssStore: rssStore,
      onSelectSection: selectWorkspaceSection,
      onSelectDraft: selectWindowDraft,
      onFocusDraft: focusWindowDraft,
      isSidebarPresented: shouldPresentWorkspaceSidebar,
      showsCompactNavigationRail: shouldShowCompactNavigationRail
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .inspector(isPresented: inspectorPresentation) {
      MetadataColumn(
        store: store,
        selectedSection: windowSession.selectedSection,
        selectedDraftID: windowSession.selectedDraftID,
        rssStore: rssStore,
        repositoryContextStage: repositoryContextStage,
        repositoryChangedFileSelection: $repositoryChangedFileSelection,
        repositorySourceSession: repositorySourceSession,
        aiChatSurfaceState: $aiChatInspectorSurfaceState,
        knowledgeInspectorPresentation: $knowledgeInspectorPresentation,
        aiChatOperationSession: aiChatInspectorOperationSession,
        prioritizesChecks: compactLayout,
        onResetWidth: resetInspectorWidth
      )
      .id(inspectorWidthResetGeneration)
      .inspectorColumnWidth(
        min: inspectorColumnWidthState.constraints.minimum,
        ideal: inspectorColumnWidthState.preferredWidth,
        max: inspectorColumnWidthState.constraints.maximum
      )
    }
    .disabled(shellState.isQuickHideActive)
    .accessibilityHidden(shellState.isQuickHideActive)
  }

  private func resetInspectorWidth() {
    inspectorWidthResetGeneration &+= 1
    updateInspectorWidthState(
      isAIAssistantPresented: presentationState.isAssistantPresented
    )
  }

  private var quickHideOverlay: some View {
    ZStack {
      if shellState.isQuickHideActive {
        QuickHideOverlay(store: store)
          .transition(
            WorkbenchMotion.statusTransition(reduceMotion: accessibilityReduceMotion)
          )
      }
    }
    .zIndex(3)
    .animation(
      WorkbenchMotion.animation(
        for: .statusChange,
        reduceMotion: accessibilityReduceMotion
      ),
      value: shellState.isQuickHideActive
    )
  }

  private func updateInspectorWidthState(isAIAssistantPresented: Bool) {
    let target = WorkspaceInspectorWidthState(
      isAIAssistantPresented: isAIAssistantPresented
    )
    guard target != inspectorWidthState else { return }

    var transaction = Transaction(
      animation: WorkbenchMotion.animation(
        for: .drawerPresentation,
        reduceMotion: accessibilityReduceMotion
      )
    )
    transaction.disablesAnimations = accessibilityReduceMotion
    withTransaction(transaction) {
      inspectorWidthState = target
    }
  }

  private func handleContentViewAppear() {
    updateInspectorWidthState(
      isAIAssistantPresented: presentationState.isAssistantPresented
    )
    applyWorkbenchPreferences()
    configureRepositoryContentChangeMonitor()
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
      isInspectorPresented: inspectorPresentation.wrappedValue,
      canToggleInspector: shellState.canUseProtectedWorkbench
        && !isSettingsWorkspacePresented
        && supportsInspector
        && canRequestInspectorInCurrentLayout,
      repositorySourceHasUnsavedChanges: repositorySourceSession.hasUnsavedChanges,
      isSettingsWorkspacePresented: isSettingsWorkspacePresented
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
      settingsWorkspaceCommandAction: settingsWorkspaceCommandAction,
      draftFullTextSearchAction: DraftFullTextSearchAction(open: openDraftFullTextSearch),
      workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction(
        isActive: effectiveFocusMode,
        canToggle: shellState.canUseProtectedWorkbench
          && windowSession.selectedSection == .writing,
        toggle: toggleFocusMode
      ),
      workspaceInspectorCommandAction: WorkspaceInspectorCommandAction(
        isPresented: inspectorPresentation.wrappedValue,
        canToggle: shellState.canUseProtectedWorkbench
          && !isSettingsWorkspacePresented
          && supportsInspector
          && canRequestInspectorInCurrentLayout,
        exitsFocusMode: effectiveFocusMode,
        toggle: toggleWorkspaceInspector
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

  private var settingsWorkspaceCommandAction: SettingsWorkspaceCommandAction {
    SettingsWorkspaceCommandAction(
      isPresented: isSettingsWorkspacePresented,
      open: openSettingsWorkspace,
      close: closeSettingsWorkspace
    )
  }

  private func openSettingsWorkspace(destination: SettingsDestination?) {
    guard shellState.canUseProtectedWorkbench else { return }
    if isSettingsWorkspacePresented, destination == nil {
      return
    }

    modalPresentation.dismiss()
    hideInspectorIfNeeded()
    settingsWorkspaceDestination = destination
    settingsWorkspaceNavigationRequestID = UUID()
    isSettingsWorkspacePresented = true
  }

  private func closeSettingsWorkspace() {
    isSettingsWorkspacePresented = false
    settingsWorkspaceDestination = nil
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

  /// The publishing surface is a trailing workspace overlay rather than a
  /// modal sheet. All other modal presentations keep using the shared sheet
  /// router, and replacing the current presentation closes the overlay.
  private var sheetModalPresentationBinding: Binding<WorkspaceModalPresentation?> {
    Binding(
      get: {
        guard modalPresentation.presented != .publishDrawer else { return nil }
        return modalPresentation.presented
      },
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
        isPersistenceResetConfirmationPresented = true
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
        let animation =
          presentation == .publishDrawer
          ? WorkbenchMotion.animation(
            for: .drawerPresentation,
            reduceMotion: accessibilityReduceMotion
          )
          : nil
        withAnimation(animation) {
          if isPresented {
            modalPresentation.present(presentation)
          } else {
            modalPresentation.dismiss(presentation)
          }
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
      LocalSitePreviewPanelView(store: store)
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
        onSelectSection: selectWorkspaceSection,
        onFocusDraft: { draftID in
          focusWindowDraft(draftID, section: .writing)
        },
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
        configureRepositoryContentChangeMonitor()
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
    repositoryContentChangeMonitor.requestImport()
  }

  private func configureRepositoryContentChangeMonitor() {
    guard scenePhase == .active, !store.isSafeMode else {
      repositoryContentChangeMonitor.stop(clientID: repositoryContentMonitorClientID)
      return
    }
    repositoryContentChangeMonitor.start(clientID: repositoryContentMonitorClientID)
  }

  private func configureOperationalPolling() {
    guard scenePhase == .active, !store.isSafeMode else {
      store.stopOperationalPolling(clientID: operationalPollingClientID)
      return
    }
    store.startOperationalPolling(clientID: operationalPollingClientID)
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
    if !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty,
      !store.hasUnsavedChanges,
      !store.isPersistenceRecoveryWriteProtected
    {
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

  private func finishFirstRunSetup(
    _ completion: FirstRunSetupCompletion
  ) -> FirstRunSetupCommitResult {
    let commitResult = FirstRunSetupPersistenceCommit.apply(completion, to: store)
    guard commitResult == .completed else { return commitResult }

    didCompleteFirstRunSetup = true
    modalPresentation.dismiss(.firstRunSetup)
    switch completion.path.destination {
    case .repositoryWizard:
      store.runPreflight()
      selectWorkspaceSection(.sync)
      Task {
        await store.repository.scanAsync()
      }
    case .siteStarter:
      selectWorkspaceSection(.siteStarter)
    case .localDrafts:
      break
    }
    return .completed
  }

  private func skipFirstRunSetup() {
    modalPresentation.dismiss(.firstRunSetup)
  }

  private func resetPersistenceAfterConfirmation() {
    switch store.resetPersistenceAfterUnrecoverableSnapshotResult() {
    case .reset(let archiveURL):
      persistenceResetFeedback = .success(archiveURL: archiveURL)
    case .failed(let archiveURL, let message):
      let archiveDetail =
        archiveURL.map {
          String(format: String(localized: "故障数据已归档到：%@\n\n"), $0.path)
        } ?? ""
      persistenceResetFeedback = .failure(
        message: archiveDetail + message
      )
    }
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

  private var commandSearchToolbarButton: some View {
    WorkspaceCommandSearchToolbarControl(
      contextStore: sceneCommandRouter.toolbarEditorContext,
      selectedDraftID: windowSession.selectedDraftID,
      density: toolbarDensity,
      isEnabled: shellState.canUseProtectedWorkbench
    ) {
      commandPaletteEditorCommands = sceneCommandRouter.markdownEditorCommandActions
      modalPresentation.present(.commandPalette)
    }
  }

  /// Each control is a direct child of the native navigation group. Keeping
  /// them in an HStack makes AppKit flatten the AX tree and associate later
  /// buttons with the sidebar toggle's label.
  private var workspaceNavigationToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      if !isSettingsWorkspacePresented {
        WorkspaceSidebarToggleToolbarButton(
          visibility: workspaceSidebarVisibility,
          action: toggleWorkspaceSidebar
        )
        .accessibilityHidden(shellState.isQuickHideActive)

        WorkspaceToolbarLeadingContent(
          store: store,
          isCompact: isCompactLayout
        )
        .disabled(!shellState.canUseProtectedWorkbench)
        .accessibilityHidden(shellState.isQuickHideActive)

        if windowSession.selectedSection.showsPublishingStatusToolbar {
          PublishingStatusToolbarControl(
            store: store,
            canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
            selectedDraftID: windowSession.selectedDraftID,
            selectedSection: windowSession.selectedSection,
            isCompact: isCompactLayout,
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
      }
    }
  }

  @ToolbarContentBuilder
  private var workspacePrimaryActionToolbar: some ToolbarContent {
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        workspacePrimaryActionToolbarGroup
          .sharedBackgroundVisibility(.hidden)
      } else {
        workspacePrimaryActionToolbarGroup
      }
    #else
      workspacePrimaryActionToolbarGroup
    #endif
  }

  private var workspacePrimaryActionToolbarGroup: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if !isSettingsWorkspacePresented {
        switch WorkspaceToolbarContextPolicy.primaryActionContext(
          for: windowSession.selectedSection
        ) {
        case .rssReading:
          WorkspaceRSSReadingToolbar(
            rssStore: rssStore,
            commandRouter: sceneCommandRouter,
            isEnabled: shellState.canUseProtectedWorkbench && !shellState.isQuickHideActive
          )

          if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
            inspectorToolbarButton
          }

          settingsToolbarButton
        case .publishing:
          let previewAvailability = WorkspaceTopBarPresentation.PreviewAvailability(
            isLivePreviewEnabled: shellState.canUseProtectedWorkbench
              && !shellState.isQuickHideActive,
            isLivePreviewRunning: localSitePreviewState.runtimeStatus.isRunning,
            isBrowserPreviewEnabled: shellState.canUseProtectedWorkbench
              && !shellState.isQuickHideActive
              && windowSession.selectedDraftID != nil
              && !externalBrowserPreviewCoordinator.isBusy
          )

          // These must stay direct ToolbarItemGroup children. In particular, do
          // not restore the former HStack wrapper: it merged browser preview
          // into the live preview accessibility element on native macOS.
          WorkspaceLivePreviewToolbarButton(
            availability: previewAvailability,
            openLivePreview: openLocalSitePreview
          )

          WorkspaceBrowserPreviewToolbarButton(
            availability: previewAvailability,
            openBrowserPreview: {
              guard let selectedDraftID = windowSession.selectedDraftID else { return }
              externalBrowserPreviewCoordinator.openCurrentArticle(for: selectedDraftID)
            }
          )

          Divider()
            .frame(height: 18)
            .padding(.horizontal, 1)
            .accessibilityHidden(true)

          WorkspaceTaskCenterToolbarButton(
            store: store,
            isCompact: isCompactLayout
          )
          .disabled(!shellState.canUseProtectedWorkbench || shellState.isQuickHideActive)

          aiAssistantToolbarButton

          if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
            inspectorToolbarButton
          }

          Divider()
            .frame(height: 18)
            .padding(.horizontal, 1)
            .accessibilityHidden(true)

          settingsToolbarButton
          WorkspacePreparePublishToolbarButton(
            isEnabled: shellState.canUseProtectedWorkbench
              && windowSession.selectedDraftID != nil,
            density: toolbarDensity,
            action: { openPublishDrawer(message: nil) }
          )
        }
      }
    }
  }

  private var aiAssistantToolbarButton: some View {
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
  }

  private var inspectorToolbarButton: some View {
    Button(action: toggleWorkspaceInspector) {
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

  private var settingsToolbarButton: some View {
    Button {
      openSettingsWorkspace(destination: nil)
    } label: {
      Label(String(localized: "设置"), systemImage: "gearshape")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: false
      )
    )
    .disabled(!shellState.canUseProtectedWorkbench)
    .help(String(localized: "设置…") + " (⌘,)")
    .accessibilityLabel(String(localized: "设置"))
    .accessibilityIdentifier("workspace-open-settings")
  }

  private var isAIAssistantWorkspaceVisible: Bool {
    presentationState.isAssistantPresented && inspectorPresentation.wrappedValue
  }

  private func toggleAIAssistantWorkspace() {
    if isAIAssistantWorkspaceVisible {
      store.ai.hideAssistant()
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
    if effectiveFocusMode && canRequestInspectorInCurrentLayout {
      return String(localized: "显示 Inspector 并退出专注")
    }
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

  private var isPublishDrawerPresented: Bool {
    modalPresentation.presented == .publishDrawer
  }

  private func normalizeWorkspacePresentation(for section: WorkspaceSection) {
    if section != .writing {
      isFocusMode = false
    }
    guard windowSession.isKeyWindow else { return }
    if section != .writing && presentationState.isAssistantPresented {
      presentationState.hideAssistant()
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
      case .some(.settings):
        openSettingsWorkspace(destination: .tab(.configurationStatus))
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

  private func toggleWorkspaceInspector() {
    guard shellState.canUseProtectedWorkbench else { return }
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
    hideInspectorIfNeeded()
    withAnimation(
      WorkbenchMotion.animation(
        for: .drawerPresentation,
        reduceMotion: accessibilityReduceMotion
      )
    ) {
      modalPresentation.present(.publishDrawer)
    }
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

  private var toolbarDensity: WorkspaceTopBarPresentation.Density {
    switch responsiveLayout.band {
    case .constrained:
      return .minimal
    case .compactInspector:
      return .compact
    case .standardInspector, .htmlSourceInspector:
      return .expanded
    }
  }

  private func applyResponsiveLayout(_ snapshot: WorkspaceResponsiveLayoutSnapshot) {
    guard snapshot != responsiveLayout else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      responsiveLayout = snapshot
      if !canOverrideInspector(snapshot) {
        revealsInspectorInCompactWorkspace = false
      }
    }
  }

  private var allowsInspectorInCurrentLayout: Bool {
    allowsInspectorByWidth
      || (canOverrideInspectorInCurrentLayout && revealsInspectorInCompactWorkspace)
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
    snapshot.canManuallyRevealInspector(for: windowSession.selectedSection)
  }

  private var canRequestInspectorInCurrentLayout: Bool {
    allowsInspectorInCurrentLayout || canOverrideInspectorInCurrentLayout
  }

  private var effectiveFocusMode: Bool {
    isFocusMode
  }

  private var hidesWorkspaceSidebarForCompactInspector: Bool {
    revealsInspectorInCompactWorkspace
      && canOverrideInspectorInCurrentLayout
      && shellState.isInspectorPresented
      && supportsInspector
  }

  private var shouldPresentWorkspaceSidebar: Bool {
    isSidebarPresented && !hidesWorkspaceSidebarForCompactInspector
  }

  private var shouldShowCompactNavigationRail: Bool {
    WorkspaceSidebarVisibilityPolicy.shouldShowCompactNavigationRail(
      userWantsVisible: isSidebarPresented,
      isFocusMode: effectiveFocusMode,
      inspectorTemporarilyReplacesSidebar: hidesWorkspaceSidebarForCompactInspector
    )
  }

  private var isWorkspaceSidebarVisible: Bool {
    WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
      userWantsVisible: shouldPresentWorkspaceSidebar,
      isFocusMode: effectiveFocusMode
    )
  }

  private var workspaceSidebarVisibility: WorkspaceTopBarPresentation.SidebarVisibility {
    isWorkspaceSidebarVisible ? .visible : .hidden
  }

  @discardableResult
  private func prepareInspectorForUserRequest() -> Bool {
    if !allowsInspectorInCurrentLayout {
      guard canOverrideInspectorInCurrentLayout else {
        return false
      }
      revealsInspectorInCompactWorkspace = true
    }

    dismissPublishDrawerForInspectorRequestIfNeeded()
    return true
  }

  private func dismissPublishDrawerForInspectorRequestIfNeeded() {
    guard isPublishDrawerPresented else { return }
    withAnimation(
      WorkbenchMotion.animation(
        for: .drawerPresentation,
        reduceMotion: accessibilityReduceMotion
      )
    ) {
      modalPresentation.dismiss(.publishDrawer)
    }
  }

  private func toggleFocusMode() {
    guard windowSession.selectedSection == .writing else { return }
    if isFocusMode {
      isFocusMode = false
    } else {
      isFocusMode = true
    }
  }

  private func toggleWorkspaceSidebar() {
    if effectiveFocusMode {
      isFocusMode = false
      isSidebarPresented = true
      return
    }

    if hidesWorkspaceSidebarForCompactInspector {
      revealsInspectorInCompactWorkspace = false
      store.setInspectorPresented(false)
      isSidebarPresented = true
      return
    }

    isSidebarPresented.toggle()
  }
}

@MainActor
private struct WorkspaceCommandSearchToolbarControl: View {
  @ObservedObject private var contextStore: WorkspaceToolbarEditorContextStore
  let selectedDraftID: UUID?
  let density: WorkspaceTopBarPresentation.Density
  let isEnabled: Bool
  let action: () -> Void

  init(
    contextStore: WorkspaceToolbarEditorContextStore,
    selectedDraftID: UUID?,
    density: WorkspaceTopBarPresentation.Density,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) {
    _contextStore = ObservedObject(wrappedValue: contextStore)
    self.selectedDraftID = selectedDraftID
    self.density = density
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    WorkspaceCommandSearchNativeHost(
      density: density,
      statistics: statistics,
      isEnabled: isEnabled,
      action: action
    )
    .frame(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
  }

  private var statistics: WorkspaceTopBarPresentation.ContextStatistics {
    guard let context = contextStore.context,
      context.draftID == selectedDraftID
    else {
      return .init()
    }
    return .init(
      wordCount: context.writingUnitCount,
      readingMinutes: context.readingMinutes
    )
  }
}


struct WorkspacePublishDrawerLayoutPolicy {
  static let minimumWidth: CGFloat = 380
  static let idealWidth: CGFloat = 500
  static let availableWidthRatio: CGFloat = 0.45

  static func width(for availableWidth: CGFloat) -> CGFloat {
    let nonnegativeWidth = max(0, availableWidth)
    let proposedWidth = min(
      idealWidth,
      max(minimumWidth, nonnegativeWidth * availableWidthRatio)
    )
    return min(proposedWidth, nonnegativeWidth)
  }
}

/// Publishing is presented above the workspace rather than as a native
/// inspector column. A native inspector participates in split-view sizing and
/// compresses the source list; this trailing overlay leaves the established
/// sidebar and editor widths untouched while the user reviews the publish flow.
private struct WorkspacePublishDrawerOverlay: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  let store: WorkbenchStore
  @Binding var isPresented: Bool

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        Spacer(minLength: 0)

        Divider()

        PublishDrawerView(
          publishingFacade: publishingFacade,
          store: store,
          isPresented: $isPresented
        )
        .frame(width: WorkspacePublishDrawerLayoutPolicy.width(for: geometry.size.width))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.16), radius: 18, x: -6, y: 0)
      }
    }
    .accessibilityIdentifier("workspace-publish-drawer-overlay")
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
