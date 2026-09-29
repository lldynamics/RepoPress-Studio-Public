import AppKit
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct ContentView: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  let store: WorkbenchStore
  let rssStore: RSSReaderStore
  @ObservedObject private var rootPresentation: WorkbenchRootPresentationFeatureFacade
  @EnvironmentObject private var launchCoordinator: WorkbenchLaunchCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.openSettings) private var openSettingsWindow
  @Environment(\.openWindow) private var openWindow
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
  @State private var isShortcutHelpPresented = false
  @State private var isTaskCenterPresented = false
  @State private var modalPresentation = WorkspaceModalPresentationState()
  @State private var firstRunHandoffProfile: SiteProfile?
  @State private var commandPaletteArticleRequest: DraftFullTextSearchRequest?
  @State private var deferredFullTextSearchRequest: DraftFullTextSearchRequest?
  @State private var publishDrawerInitialScope: PublishScope = .repository
  @State private var directPublishCompletedRecordID: UUID?
  @State private var pendingDirectSingleReview: SinglePublishReviewSnapshot?
  @State private var isPreparingCurrentArticlePublish = false
  @State private var isPublishingCurrentArticle = false
  @State private var publishReadinessNavigationRequest: PublishReadinessNavigationRequest?
  @State private var readinessInspectorSheet: PublishReadinessNavigationRequest?
  @State private var articlePublishRepairSession: ArticlePublishRepairSession?
  @State private var isReturningToPublishChecks = false
  @State private var articleInspectorPresentation = ArticleInspectorPresentationState()
  @State private var commandPaletteEditorCommands: MarkdownEditorCommandActions?
  @State private var commandPaletteDraftID: UUID?
  @State private var deferredPaletteAIRequest = WorkspaceDeferredAIRequestState()
  @State private var deferredContentSearchRequest = WorkspaceDeferredContentSearchRequest()
  @State private var responsiveLayout = WorkspaceResponsiveLayoutSnapshot.initial
  @State private var repositoryContentMonitorClientID = UUID()
  @State private var operationalPollingClientID = UUID()
  @State private var aiChatInspectorSurfaceState = AIChatSurfaceState(surface: .inspector)
  // These reference models need stable window lifetime, but ContentView does
  // not read their published values. Feature leaves observe them directly.
  @State private var aiChatInspectorOperationSession = AIChatSurfaceOperationSession()
  @State private var rssPresentation = RSSReaderPresentationState()
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var imageWorkbenchContextStage: ImageWorkbenchContextStage = .resources
  @State private var imageBrowserSession = RepositoryImageBrowserSession()
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  @State private var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @State private var knowledgeInspectorPresentation = KnowledgeLibraryInspectorPresentationState()
  @StateObject private var repositorySourceSession: RepositoryHTMLSourceSession
  @State private var localSitePreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @StateObject private var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  @StateObject private var repositoryContentChangeMonitor: RepositoryContentChangeMonitorCoordinator
  @State private var sceneCommandRouter = WorkspaceSceneCommandRouter()
  @StateObject private var windowSession: WorkspaceWindowSession
  @State private var windowTitleRegistrationID = UUID()
  @State private var inspectorWidthState = WorkspaceInspectorWidthState(
    isAIAssistantPresented: false
  )
  @State private var inspectorWidthResetGeneration = 0

  private var shellState: WorkbenchRootPresentationFeatureFacade { rootPresentation }
  private var presentationState: WorkbenchRootPresentationFeatureFacade { rootPresentation }

  @ObservedObject private var windowTitleRegistry = WorkspaceWindowTitleRegistry.shared

  private var mainWindowBaseTitle: String {
    let profileName = store.activeProfile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let workspaceName = profileName.isEmpty ? String(localized: "本地工作台") : profileName
    let contextName: String
    if windowSession.selectedSection == .writing,
      let draftID = windowSession.selectedDraftID,
      let draft = store.draft(for: draftID)
    {
      let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
      contextName = title.isEmpty ? String(localized: "未命名文章") : String(title.prefix(48))
    } else {
      contextName = WorkspaceNavigationRouteDescriptor.title(for: windowSession.selectedSection)
    }
    return "\(contextName) — \(workspaceName)"
  }

  private var mainWindowTitle: String {
    windowTitleRegistry.displayTitle(
      for: windowTitleRegistrationID,
      baseTitle: mainWindowBaseTitle
    )
  }

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
        selectedDraftID: store.selectedDraftID,
        moduleVisibility: .load(defaults: .standard)
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

      ZStack(alignment: .bottom) {
        workspaceCenterLayout(
          compactLayout: compactLayout,
          isInspectorVisible: isInspectorVisible,
          inspectorColumnWidthState: inspectorColumnWidthState
        )

        if isPublishDrawerPresented {
          WorkspacePublishDrawerOverlay(
            publishingFacade: store.publishing,
            store: store,
            isPresented: modalIsPresentedBinding(.publishDrawer),
            initialScope: publishDrawerInitialScope,
            initialCompletedReleaseRecordID: directPublishCompletedRecordID,
            onNavigateIssue: navigateToPublishIssue
          )
          .transition(
            WorkbenchMotion.drawerTransition(reduceMotion: accessibilityReduceMotion)
          )
          .zIndex(2)
        }

        if isPreparingCurrentArticlePublish || isPublishingCurrentArticle {
          Label(
            isPreparingCurrentArticlePublish ? "正在准备当前文章确认…" : "正在发布当前文章…",
            systemImage: "paperplane"
          )
          .font(.callout.weight(.medium))
          .padding(12)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
          .padding(.bottom, 20)
          .zIndex(3)
          .accessibilityIdentifier("current-article-publish-progress")
        }

        if let repairSession = articlePublishRepairSession {
          ArticlePublishRepairBar(
            session: repairSession,
            isReturningToPublishChecks: isReturningToPublishChecks,
            returnToPublishChecks: { returnToPublishChecks(from: repairSession) },
            endRepair: { endArticlePublishRepair(repairSession) }
          )
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(1)
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
    }
  }

  /// Keep environment injection and native toolbar construction together:
  /// their relative order is part of the scene contract, but neither needs to
  /// participate in lifecycle modifier type inference.
  private var workspaceToolbarAndEnvironmentContent: some View {
    workspaceRootContent
      .navigationTitle(mainWindowTitle)
      .environment(\.publishReadinessNavigationRequest, publishReadinessNavigationRequest)
      .environment(\.workspaceWindowID, windowSession.windowID)
      .environment(\.workspaceWindowSession, windowSession)
      .modifier(WritingListWindowStorageModifier(state: windowSession.writingListState))
      .environment(\.workspaceWindowIsKey, windowSession.isKeyWindow)
      .environment(
        \.settingsWorkspaceCommandAction,
        settingsWorkspaceCommandAction
      )
      .background(WorkbenchAccessibilityStatusAnnouncer(activityStatus: store.activityStatus))
      .safeAreaInset(edge: .top, spacing: 0) {
        if store.isSafeMode {
          WorkbenchSafeModeBanner()
        }
      }
      .environment(
        \.publishDrawerCommandAction,
        publishDrawerCommandAction
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
          isAvailable: canRequestInspectorInCurrentLayout,
          unavailableReason: canRequestInspectorInCurrentLayout
            ? nil
            : String(localized: "扩大窗口后可使用详情栏"),
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

        // With the window title hidden, a principal item supplies the flexible
        // center; otherwise the primary actions pack beside the navigation group.
        ToolbarItem(placement: .principal) {
          commandSearchToolbarButton
        }

        workspacePrimaryActionToolbar
      }
      .onChange(of: localSitePreviewState.activeProfileID) {
        externalBrowserPreviewCoordinator.cancelPendingOpen()
      }
      .onChange(of: windowSession.selectedDraftID) { _, draftID in
        externalBrowserPreviewCoordinator.cancelPendingOpen(ifDraftIsNoLongerCurrent: draftID)
      }
      .background(MainWindowInitialSizeBridge())
  }

  /// Lifecycle, state synchronization, and sheet presentation are deliberately
  /// a second type-check boundary after the native toolbar chain.
  private var workspaceLifecycleContent: some View {
    workspaceToolbarAndEnvironmentContent
      .onAppear {
        restoreWindowSessionStorageIfNeeded()
        registerWindowTitle()
        synchronizeWindowSessionActivity()
        configureRepositoryContentChangeMonitor()
        configureOperationalPolling()
      }
      .onChange(of: sceneCommandRouterRootUpdateKey, initial: true) { _, _ in
        updateSceneCommandRouterRootActions()
      }
      .onDisappear(perform: handleContentViewDisappear)
      .onChange(of: mainWindowBaseTitle) { _, _ in
        registerWindowTitle()
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
      .onChange(of: scenePhase) { oldPhase, newPhase in
        handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
      }
      .onChange(of: controlActiveState) { _, _ in
        synchronizeWindowSessionActivity()
      }
      .onChange(of: shellState.selectedSection) { _, section in
        windowSession.receiveSharedSection(section)
        if windowSession.isKeyWindow, !moduleVisibility.allows(section) {
          store.selectSection(moduleVisibility.resolvedSection(section))
        }
      }
      .onChange(of: moduleVisibility) { _, visibility in
        windowSession.updateModuleVisibility(visibility) { store.selectSection($0) }
        launchCoordinator.startBackgroundRefreshIfNeeded(for: rssStore)
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
      .workspacePersistenceRecovery(store: store)
      .sheet(item: $readinessInspectorSheet) { request in
        readinessInspectorSheetContent(request)
      }
      .sheet(isPresented: $isDraftRecoveryPresented, content: draftRecoveryPanel)
      .sheet(isPresented: $isShortcutHelpPresented) {
        MarkdownShortcutHelpPanel()
      }
      .sheet(isPresented: $isTaskCenterPresented) {
        WorkspaceTaskCenterView(store: store, windowSession: windowSession)
          .environment(\.workspaceWindowID, windowSession.windowID)
          .environment(\.workspaceWindowSession, windowSession)
          .focusedSceneObject(sceneCommandRouter)
      }
      .sheet(
        item: sheetModalPresentationBinding,
        onDismiss: handleWorkspaceSheetDismissal,
        content: modalContent
      )
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
    Task {
      await store.knowledge.refreshNoteCloudSync()
      _ = try? await store.knowledge.createAutomaticNoteSnapshotIfDue()
    }
    configureRepositoryContentChangeMonitor()
    refreshExternallyCreatedDrafts()
    configureOperationalPolling()
    refreshStaleRSSIfNeeded()
  }

  private func handleContentViewDisappear() {
    windowTitleRegistry.unregister(windowTitleRegistrationID)
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

  private func registerWindowTitle() {
    windowTitleRegistry.register(
      windowID: windowSession.windowID,
      registrationID: windowTitleRegistrationID,
      baseTitle: mainWindowBaseTitle
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
    if let repairSession = articlePublishRepairSession, repairSession.draftID != draftID {
      endArticlePublishRepair(
        repairSession,
        message: String(localized: "已切换文章，已结束当前发布问题修复。")
      )
    }
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
      writingListState: windowSession.writingListState,
      isCompact: compactLayout,
      isFocusMode: effectiveFocusMode,
      isInspectorPresented: isInspectorVisible,
      contentHealthFilter: $contentHealthFilter,
      imageWorkbenchContextStage: $imageWorkbenchContextStage,
      imageBrowserSession: imageBrowserSession,
      repositoryContextStage: $repositoryContextStage,
      repositoryChangedFileSelection: $repositoryChangedFileSelection,
      knowledgeInspectorPresentation: $knowledgeInspectorPresentation,
      repositorySourceSession: repositorySourceSession,
      rssStore: rssStore,
      rssPresentation: rssPresentation,
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
        imageBrowserSession: imageBrowserSession,
        onOpenImageDraft: { focusWindowDraft($0, section: .writing) },
        rssStore: rssStore,
        repositoryChangedFileSelection: $repositoryChangedFileSelection,
        aiChatSurfaceState: $aiChatInspectorSurfaceState,
        knowledgeInspectorPresentation: $knowledgeInspectorPresentation,
        aiChatOperationSession: aiChatInspectorOperationSession,
        prioritizesChecks: compactLayout,
        articlePresentation: articleInspectorPresentation,
        defaultWidth: inspectorColumnWidthState.preferredWidth,
        onResetWidth: resetInspectorWidth
      )
      .id(inspectorWidthResetGeneration)
      .inspectorColumnWidth(
        min: inspectorColumnWidthState.constraints.minimum,
        ideal: inspectorColumnWidthState.preferredWidth,
        max: inspectorColumnWidthState.constraints.maximum
      )
    }
  }

  private func resetInspectorWidth() {
    inspectorWidthResetGeneration &+= 1
    updateInspectorWidthState(
      isAIAssistantPresented: presentationState.isAssistantPresented
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
    performDeferredPaletteAIRequestIfReady()
    performDeferredFullTextSearchIfReady()
    performDeferredContentSearchIfReady()
  }

  private var sceneCommandRouterRootUpdateKey: WorkspaceSceneCommandRouter.RootUpdateKey {
    WorkspaceSceneCommandRouter.RootUpdateKey(
      selectedSection: windowSession.selectedSection,
      isFocusModeActive: effectiveFocusMode,
      canToggleFocusMode: windowSession.selectedSection == .writing,
      isSidebarPresented: isWorkspaceSidebarVisible,
      isInspectorPresented: inspectorPresentation.wrappedValue,
      canToggleInspector: supportsInspector && canRequestInspectorInCurrentLayout,
      publishableArticleID: publishableArticleID
    )
  }

  private func updateSceneCommandRouterRootActions() {
    let commandRouter = sceneCommandRouter
    sceneCommandRouter.updateRoot(
      publishDrawerCommandAction: publishDrawerCommandAction,
      localSitePreviewCommandAction: LocalSitePreviewCommandAction {
        openLocalSitePreview()
      },
      workspaceCommandPaletteAction: WorkspaceCommandPaletteAction(
        open: { [weak commandRouter] in
          commandPaletteArticleRequest = nil
          commandPaletteDraftID = windowSession.selectedDraftID
          commandPaletteEditorCommands = commandRouter?.markdownEditorCommandActions
          modalPresentation.present(.commandPalette)
        },
        openMaintenance: openMaintenanceSubpage,
        openReleaseHistory: openReleaseHistorySubpage
      ),
      workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction {
        firstRunHandoffProfile = nil
        modalPresentation.present(.firstRunSetup)
      },
      settingsWorkspaceCommandAction: settingsWorkspaceCommandAction,
      draftFullTextSearchAction: DraftFullTextSearchAction(
        open: openDraftFullTextSearch, openRequest: requestDraftFullTextSearch
      ),
      workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction(
        isActive: effectiveFocusMode,
        canToggle: windowSession.selectedSection == .writing,
        toggle: toggleFocusMode
      ),
      workspaceSidebarCommandAction: WorkspaceSidebarCommandAction(
        isPresented: isWorkspaceSidebarVisible,
        canToggle: true,
        toggle: toggleWorkspaceSidebar
      ),
      workspaceInspectorCommandAction: WorkspaceInspectorCommandAction(
        isPresented: inspectorPresentation.wrappedValue,
        canToggle: supportsInspector
          && canRequestInspectorInCurrentLayout,
        exitsFocusMode: effectiveFocusMode,
        toggle: toggleWorkspaceInspector
      ),
      showShortcutHelp: { isShortcutHelpPresented = true },
      showTaskCenter: openTaskCenter
    )
  }

  private func openTaskCenter() {
    isTaskCenterPresented = true
  }

  private var settingsWorkspaceCommandAction: SettingsWorkspaceCommandAction {
    SettingsWorkspaceCommandAction(open: openSettings)
  }

  private func openSettings(destination: SettingsDestination?) {
    _ = activateCurrentWindowSharedContext()
    SettingsNavigation.open(destination: destination) {
      openSettingsWindow()
    }
  }

  private func refreshStaleRSSIfNeeded() {
    guard
      RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
        isSceneActive: scenePhase == .active,
        isSafeMode: store.isSafeMode,
        isEnabled: moduleVisibility.rssEnabled && isRSSBackgroundRefreshEnabled,
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
        isPresented: modalIsPresentedBinding(.publishDrawer),
        initialScope: publishDrawerInitialScope,
        onNavigateIssue: navigateToPublishIssue
      )
      .frame(minWidth: 680, idealWidth: 780, minHeight: 600, idealHeight: 720)
    case .singleArticlePublishConfirmation:
      if let review = pendingDirectSingleReview {
        let presentation = PublishDrawerSingleArticleActionPresentation.make(
          isWebsiteDraft: review.draft.draft
        )
        RemotePublishConfirmationView(
          targetLabel: review.draft.draft ? String(localized: "网站草稿") : String(localized: "文章"),
          targetTitle: review.draft.title,
          purpose: presentation.confirmationPurpose,
          preview: review.preview,
          reviewDraft: review.reviewDraft,
          isPublishing: isPublishingCurrentArticle || store.isRemoteRepositoryPublishing,
          cancelAction: {
            pendingDirectSingleReview = nil
            modalPresentation.dismiss(.singleArticlePublishConfirmation)
          },
          confirmAction: {
            pendingDirectSingleReview = nil
            modalPresentation.dismiss(.singleArticlePublishConfirmation)
            Task { @MainActor in await publishDirectCurrentArticle(review) }
          }
        )
      }
    case .firstRunSetup:
      if let profile = firstRunHandoffProfile {
        FirstRunRepositoryHandoffView(
          prepare: { isRetry in
            guard
              let expectedProfile = FirstRunRepositoryHandoffPresentation.profileForPreparation(
                original: profile, current: store.activeProfile, isRetry: isRetry
              )
            else { return .cancelled }
            firstRunHandoffProfile = expectedProfile
            let result = await store.prepareRepositoryForWriting(expectedProfile: expectedProfile)
            return FirstRunRepositoryHandoffPresentation.state(
              result: result, drafts: store.drafts, profileID: expectedProfile.id
            )
          },
          openDraft: { draftID in
            guard store.activeProfile == profile,
              store.drafts.contains(where: {
                $0.id == draftID && $0.belongs(toSiteProfileID: profile.id)
              })
            else { return false }
            skipFirstRunSetup()
            focusWindowDraft(draftID, section: .writing)
            return true
          },
          createDraft: {
            guard store.activeProfile == profile else {
              return false
            }
            let draftID = store.createDraftWithoutChangingSelection()
            skipFirstRunSetup()
            focusWindowDraft(draftID, section: .writing)
            return true
          },
          inspectRepository: {
            skipFirstRunSetup()
            if store.activeProfile == profile { selectWorkspaceSection(.sync) }
          },
          close: skipFirstRunSetup
        )
      } else {
        FirstRunSetupView(
          store: store,
          finish: finishFirstRunSetup,
          skip: skipFirstRunSetup
        )
      }
    case .commandPalette:
      WorkspaceCommandPalette(
        store: store,
        rssStore: rssStore,
        editorCommands: commandPaletteEditorCommands,
        contextDraftID: commandPaletteDraftID,
        initialArticleSearch: commandPaletteArticleRequest,
        onSelectSection: selectWorkspaceSection,
        onFocusDraft: { draftID in
          focusWindowDraft(draftID, section: .writing)
        },
        onToggleFocusMode: toggleFocusMode,
        onOpenAI: { draftID, quickPrompt in
          deferredPaletteAIRequest.enqueue(draftID: draftID, quickPrompt: quickPrompt)
        },
        onOpenArticleHit: openDraftFullTextSearchHit,
        onOpenKnowledgeResult: { result, query in
          deferredContentSearchRequest.enqueue(.knowledge(result, query: query))
        },
        onOpenRSSArticle: { articleID, query in
          deferredContentSearchRequest.enqueue(.rss(articleID: articleID, query: query))
        }
      )
    }
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    private var usesInlineAIScreenshotInspector: Bool {
      ScreenshotDemoDataService.isEnabledFromEnvironment
        && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .aiChat
    }
  #endif

  private func openDraftFullTextSearch() {
    requestDraftFullTextSearch(DraftFullTextSearchRequest(query: "", scope: .allDrafts))
  }

  private func requestDraftFullTextSearch(_ request: DraftFullTextSearchRequest) {
    deferredFullTextSearchRequest = request
    if modalPresentation.presented != nil {
      modalPresentation.dismiss()
    } else {
      performDeferredFullTextSearchIfReady()
    }
  }

  private func performDeferredFullTextSearchIfReady() {
    guard modalPresentation.presented == nil,
      let request = deferredFullTextSearchRequest,
      activateCurrentWindowSharedContext()
    else { return }
    deferredFullTextSearchRequest = nil
    commandPaletteArticleRequest = request
    commandPaletteDraftID = windowSession.selectedDraftID
    commandPaletteEditorCommands = sceneCommandRouter.markdownEditorCommandActions
    modalPresentation.present(.commandPalette)
  }

  private func openDraftFullTextSearchHit(_ hit: DraftFullTextSearchHit) {
    // The sheet can make its presenting window non-key. Update that window's
    // own intent before publishing the compatibility request to the shared
    // Store, so returning from the sheet cannot restore an older article.
    focusWindowDraft(hit.draftID, section: .writing)
    store.requestEditorFocus(
      draftID: hit.draftID,
      field: hit.field.rawValue,
      query: hit.matchedText,
      selectedRange: hit.field == .body ? hit.sourceRange : nil
    )
    if let request = store.editorFocusRequest {
      windowSession.registerEditorFocusRequest(request.id)
    }
  }

  private func openLocalSitePreview() {
    guard activateCurrentWindowSharedContext() else { return }
    if !store.localSitePreviewRuntimeStatus.isRunning {
      store.startLocalSitePreview()
    }
    openWindow(id: LocalSitePreviewWindowScene.id)
  }

  private func applyWorkbenchPreferences() {
    if !didApplyInitialWorkbenchPreferences {
      // AI is an explicit writing tool; a previous session must not reclaim the Inspector on launch.
      presentationState.prepareInitialWindowPresentation()
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
    firstRunHandoffProfile = nil
    modalPresentation.present(.firstRunSetup)
  }

  private func finishFirstRunSetup(
    _ completion: FirstRunSetupCompletion
  ) -> FirstRunSetupCommitResult {
    let commitResult = FirstRunSetupPersistenceCommit.apply(completion, to: store)
    guard commitResult == .completed else { return commitResult }

    didCompleteFirstRunSetup = true
    switch completion.path.destination {
    case .repositoryWizard:
      firstRunHandoffProfile = store.activeProfile
    case .localDrafts:
      modalPresentation.dismiss(.firstRunSetup)
    }
    return .completed
  }

  private func skipFirstRunSetup() {
    modalPresentation.dismiss(.firstRunSetup)
    firstRunHandoffProfile = nil
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
      density: toolbarDensity
    ) {
      commandPaletteArticleRequest = nil
      commandPaletteDraftID = windowSession.selectedDraftID
      commandPaletteEditorCommands = sceneCommandRouter.markdownEditorCommandActions
      modalPresentation.present(.commandPalette)
    }
  }

  /// Each control is a direct child of the native navigation group. Keeping
  /// them in an HStack makes AppKit flatten the AX tree and associate later
  /// buttons with the sidebar toggle's label.
  private var workspaceNavigationToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      WorkspaceSidebarToggleToolbarButton(
        visibility: workspaceSidebarVisibility,
        action: toggleWorkspaceSidebar
      )
      WorkspaceToolbarLeadingContent(
        store: store,
        isCompact: isCompactLayout,
        openSiteSettings: {
          openSettings(destination: .tab(.configurationStatus))
        }
      )

      if windowSession.selectedSection.showsPublishingStatusToolbar {
        PublishingStatusToolbarControl(
          store: store,
          selectedDraftID: windowSession.selectedDraftID,
          selectedSection: windowSession.selectedSection,
          isCompact: isCompactLayout,
          openPublishFlow: prepareCurrentArticlePublishOrOpenDrawer,
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
      switch WorkspaceToolbarContextPolicy.primaryActionContext(
        for: windowSession.selectedSection
      ) {
      case .rssReading:
        WorkspaceRSSReadingToolbar(
          rssStore: rssStore,
          commandRouter: sceneCommandRouter
        )

        if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
          inspectorToolbarButton
        }

        settingsToolbarButton
      case .knowledgeLibrary:
        WorkspaceKnowledgeToolbar(
          commandRouter: sceneCommandRouter
        )

        if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
          inspectorToolbarButton
        }

        settingsToolbarButton
      case .images:
        WorkspaceToolbarActionButton(
          title: String(localized: "图片概览"),
          systemImage: "square.grid.2x2",
          accessibilityIdentifier: "workspace-images-overview",
          isActive: imageWorkbenchContextStage == .overview,
          showsTitle: !isCompactLayout,
          action: { imageWorkbenchContextStage = .overview }
        )
        WorkspaceToolbarActionButton(
          title: String(localized: "图片资源"),
          systemImage: "photo.stack",
          accessibilityIdentifier: "workspace-images-resources",
          isActive: imageWorkbenchContextStage == .resources,
          showsTitle: !isCompactLayout,
          action: { imageWorkbenchContextStage = .resources }
        )

        if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
          inspectorToolbarButton
        }

        settingsToolbarButton
      case .publishing:
        let previewAvailability = WorkspaceTopBarPresentation.PreviewAvailability(
          isLivePreviewRunning: localSitePreviewState.runtimeStatus.isRunning,
          isBrowserPreviewEnabled: windowSession.selectedDraftID != nil
            && !externalBrowserPreviewCoordinator.isBusy
        )

        WorkspacePreviewToolbarButton(
          availability: previewAvailability,
          showsTitle: !isCompactLayout,
          openLivePreview: openLocalSitePreview,
          openBrowserPreview: {
            guard let selectedDraftID = windowSession.selectedDraftID else { return }
            externalBrowserPreviewCoordinator.openCurrentArticle(for: selectedDraftID)
          }
        )

        WorkspaceTaskCenterToolbarButton(
          store: store,
          open: openTaskCenter
        )

        aiAssistantToolbarButton

        if supportsInspector && (!isCompactLayout || canRequestInspectorInCurrentLayout) {
          inspectorToolbarButton
        }

        settingsToolbarButton
        WorkspacePreparePublishToolbarButton(
          density: toolbarDensity,
          action: togglePublishDrawer
        )
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
        ? String(localized: "关闭 AI 助手")
        : String(localized: "在右侧打开 AI 助手")
    )
    .accessibilityLabel(String(localized: "AI 助手"))
    .accessibilityValue(
      isAIAssistantWorkspaceVisible
        ? String(localized: "AI 助手已显示")
        : String(localized: "已隐藏")
    )
    .accessibilityIdentifier("ai-assistant-toolbar-button")
    .disabled(!isAIAssistantWorkspaceVisible && !canRequestInspectorInCurrentLayout)
  }

  private var inspectorToolbarButton: some View {
    Button(action: toggleWorkspaceInspector) {
      Label(String(localized: "详情栏"), systemImage: "sidebar.right")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: inspectorPresentation.wrappedValue
          && !presentationState.isAssistantPresented
      )
    )
    .disabled(!canRequestInspectorInCurrentLayout)
    .help(inspectorToolbarHelp)
    .accessibilityLabel(String(localized: "工作区详情栏"))
    .accessibilityValue(inspectorAccessibilityValue)
    .accessibilityIdentifier("workspace-inspector-toggle")
  }

  private var settingsToolbarButton: some View {
    Button {
      openSettings(destination: nil)
    } label: {
      Label(String(localized: "设置"), systemImage: "gearshape")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: false
      )
    )
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
    guard prepareInspectorForUserRequest()
    else { return false }
    guard activateCurrentWindowSharedContext() else { return false }
    if effectiveFocusMode {
      isFocusMode = false
    }
    return store.ai.openChatWorkspace(for: draftID, quickPrompt: quickPrompt)
  }

  private func handleWorkspaceSheetDismissal() {
    firstRunHandoffProfile = nil
    deferredPaletteAIRequest.sheetDidDismiss()
    deferredContentSearchRequest.sheetDidDismiss()
    performDeferredPaletteAIRequestIfReady()
    performDeferredFullTextSearchIfReady()
    performDeferredContentSearchIfReady()
  }

  private func performDeferredContentSearchIfReady() {
    guard modalPresentation.presented == nil,
      let destination = deferredContentSearchRequest.consume(isKeyWindow: windowSession.isKeyWindow)
    else { return }
    switch destination {
    case .knowledge(let result, let query):
      guard moduleVisibility.libraryEnabled else { return }
      selectWorkspaceSection(.library)
      _ = store.knowledge.revealSearchResult(result, query: query)
    case .rss(let articleID, _):
      guard moduleVisibility.rssEnabled else { return }
      selectWorkspaceSection(.rss)
      _ = rssPresentation.openContentSearchResult(articleID, in: rssStore)
    }
  }

  private func performDeferredPaletteAIRequestIfReady() {
    guard modalPresentation.presented == nil,
      let request = deferredPaletteAIRequest.consume(isKeyWindow: windowSession.isKeyWindow)
    else { return }
    if let draftID = request.draftID {
      guard store.drafts.contains(where: { $0.id == draftID }) else { return }
      focusWindowDraft(draftID, section: .writing)
    }
    _ = openAIAssistantWorkspace(for: request.draftID, quickPrompt: request.quickPrompt)
  }

  private var inspectorToolbarHelp: String {
    if effectiveFocusMode && canRequestInspectorInCurrentLayout {
      return String(localized: "显示详情栏并退出专注")
    }
    if canOverrideInspectorInCurrentLayout && !allowsInspectorInCurrentLayout {
      return String(localized: "窗口较窄；点击后会收起左侧栏并显示详情栏")
    }
    guard allowsInspectorInCurrentLayout else {
      return String(localized: "扩大窗口后可使用详情栏")
    }
    if presentationState.isAssistantPresented {
      return String(localized: "切换到文章详情栏")
    }
    return inspectorPresentation.wrappedValue
      ? String(localized: "隐藏详情栏")
      : String(localized: "显示详情栏")
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
        openSettings(destination: .tab(.configurationStatus))
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

  private func togglePublishDrawer() {
    if isPublishDrawerPresented {
      dismissPublishDrawerIfNeeded()
    } else {
      prepareCurrentArticlePublishOrOpenDrawer()
    }
  }

  private var publishableArticleID: UUID? {
    guard windowSession.selectedSection == .writing,
      !isPreparingCurrentArticlePublish, !isPublishingCurrentArticle,
      let draftID = windowSession.selectedDraftID,
      store.draft(for: draftID) != nil
    else { return nil }
    return draftID
  }

  private var publishDrawerCommandAction: PublishDrawerCommandAction {
    let draftID = publishableArticleID
    return PublishDrawerCommandAction(
      currentArticleID: draftID,
      prepareCurrentArticle: {
        guard let draftID, publishableArticleID == draftID else { return }
        prepareCurrentArticlePublishOrOpenDrawer()
      },
      open: { message in
        openPublishDrawer(message: message, preferredScope: .repository)
      }
    )
  }

  private func prepareCurrentArticlePublishOrOpenDrawer() {
    guard windowSession.selectedSection == .writing,
      let draftID = windowSession.selectedDraftID,
      store.draft(for: draftID) != nil
    else {
      openPublishDrawer(message: nil)
      return
    }
    guard !isPreparingCurrentArticlePublish, !isPublishingCurrentArticle else { return }
    guard activateCurrentWindowSharedContext() else { return }
    let profileID = store.activeProfileID
    isPreparingCurrentArticlePublish = true
    Task { @MainActor in
      defer { isPreparingCurrentArticlePublish = false }
      let prepared = await store.prepareSelectedDraftOnlinePublish(draftID: draftID)
      guard !Task.isCancelled,
        windowSession.selectedDraftID == draftID,
        store.activeProfileID == profileID
      else { return }
      guard prepared,
        store.publishDrawerFeedback?.status != .warning,
        store.publishDrawerFeedback?.status != .failure,
        let snapshot = store.cachedDraftPublishPreviewSnapshot(for: draftID),
        let draft = store.draft(for: draftID),
        SingleArticlePublishFastPathPolicy.qualifies(
          snapshot, draftID: draftID, profileID: profileID
        )
      else {
        openPublishDrawer(
          message: nil, preferredScope: .currentArticle, preservingPublishFeedback: true
        )
        return
      }
      do {
        let review = try SinglePublishReviewSnapshot(
          draft: draft, profile: store.activeProfile, snapshot: snapshot
        )
        pendingDirectSingleReview = review
        modalPresentation.present(.singleArticlePublishConfirmation)
      } catch {
        openPublishDrawer(
          message: nil, preferredScope: .currentArticle, preservingPublishFeedback: true
        )
      }
    }
  }

  private func publishDirectCurrentArticle(_ review: SinglePublishReviewSnapshot) async {
    guard !isPublishingCurrentArticle else { return }
    isPublishingCurrentArticle = true
    defer { isPublishingCurrentArticle = false }
    let published = await PublishDrawerDirectArticlePublisher.publish(
      store: store, review: review
    )
    guard let published else {
      openPublishDrawer(
        message: nil, preferredScope: .currentArticle, preservingPublishFeedback: true
      )
      return
    }
    openPublishDrawer(
      message: nil, preferredScope: .currentArticle,
      completedRecordID: published.recordID, preservingPublishFeedback: true
    )
  }

  private func openPublishDrawer(
    message: String?,
    preferredScope: PublishScope? = nil,
    completedRecordID: UUID? = nil,
    preservingPublishFeedback: Bool = false
  ) {
    guard activateCurrentWindowSharedContext() else { return }
    clearArticlePublishRepair()
    windowSession.receiveSharedDraft(store.selectedDraftID)
    publishDrawerInitialScope = preferredScope ?? PublishScope.defaultScope
    directPublishCompletedRecordID = completedRecordID
    hideInspectorIfNeeded()
    withAnimation(
      WorkbenchMotion.animation(
        for: .drawerPresentation,
        reduceMotion: accessibilityReduceMotion
      )
    ) {
      modalPresentation.present(.publishDrawer)
    }
    if !preservingPublishFeedback {
      store.setPublishActionMessage(
        message ?? String(localized: "发布流程已打开，请选择保存到本地或发布上线。"),
        status: .information
      )
    }
  }

  private func navigateToPublishIssue(
    draftID: UUID,
    target: PublishReadinessTarget,
    publishScope: PublishScope
  ) {
    guard store.draft(for: draftID) != nil else { return }
    dismissPublishDrawerIfNeeded()
    presentationState.hideAssistant()
    isFocusMode = false
    let route = ArticlePublishRepairRoutePolicy.route(for: target)

    switch route {
    case .repository:
      clearArticlePublishRepair()
      focusWindowDraft(draftID, section: route.workspaceSection)
      repositoryContextStage = .overview

    case .article(let articleTarget):
      focusWindowDraft(draftID, section: route.workspaceSection)
      let repairSession = ArticlePublishRepairSession(
        draftID: draftID,
        target: articleTarget,
        publishScope: publishScope
      )
      articlePublishRepairSession = repairSession
      let request = PublishReadinessNavigationRequest(draftID: draftID, target: articleTarget)
      publishReadinessNavigationRequest = request
      if let tab = articleTarget.inspectorTab {
        articleInspectorPresentation.select(tab, for: draftID, section: .writing)
      }
      switch articleTarget {
      case .body(let query):
        store.requestEditorFocus(draftID: draftID, field: "body", query: query)
        if let request = store.editorFocusRequest {
          windowSession.registerEditorFocusRequest(request.id)
        }
      case .images(let attachmentID):
        if let attachmentID {
          _ = store.focusImageInspector(draftID: draftID, attachmentID: attachmentID)
        }
        revealPublishIssueInspector(request)
      case .metadata, .seo:
        revealPublishIssueInspector(request)
      case .repository:
        break
      }
    }
  }

  private func returnToPublishChecks(from repairSession: ArticlePublishRepairSession) {
    guard articlePublishRepairSession?.id == repairSession.id, !isReturningToPublishChecks else {
      return
    }
    guard let draft = store.draft(for: repairSession.draftID) else {
      endArticlePublishRepair(
        repairSession,
        message: String(localized: "文章已不存在，无法返回发布检查。")
      )
      return
    }

    isReturningToPublishChecks = true
    Task { @MainActor in
      store.runPreflight()
      _ = await store.refreshPublishPreview(for: draft.id)
      guard articlePublishRepairSession?.id == repairSession.id else { return }
      guard windowSession.selectedDraftID == repairSession.draftID else {
        endArticlePublishRepair(
          repairSession,
          message: String(localized: "已切换文章，已结束当前发布问题修复。")
        )
        return
      }
      isReturningToPublishChecks = false
      // The drawer clears repair state only after it accepts this window's
      // context. Keep the return path when focus changed during the refresh.
      openPublishDrawer(
        message: String(localized: "发布预览已刷新，请重新审阅后再发布。"),
        preferredScope: repairSession.publishScope
      )
    }
  }

  private func endArticlePublishRepair(
    _ repairSession: ArticlePublishRepairSession,
    message: String? = nil
  ) {
    guard articlePublishRepairSession?.id == repairSession.id else { return }
    clearArticlePublishRepair()
    if let message {
      store.setPublishActionMessage(message, status: .information)
    }
  }

  private func clearArticlePublishRepair() {
    articlePublishRepairSession = nil
    isReturningToPublishChecks = false
    publishReadinessNavigationRequest = nil
    readinessInspectorSheet = nil
  }

  private func revealPublishIssueInspector(_ request: PublishReadinessNavigationRequest) {
    if prepareInspectorForUserRequest() {
      store.setInspectorPresented(true)
    } else {
      readinessInspectorSheet = request
    }
  }

  @ViewBuilder
  private func readinessInspectorSheetContent(_ request: PublishReadinessNavigationRequest)
    -> some View
  {
    if let initialDraft = store.draft(for: request.draftID) {
      VStack(spacing: 0) {
        WorkspaceTaskInspector(
          section: .writing,
          draft: Binding(
            get: { store.draft(for: request.draftID) ?? initialDraft },
            set: { store.updateDraftFromEditor($0) }
          ),
          store: store,
          rssStore: rssStore,
          presentation: articleInspectorPresentation
        )
        Button("完成") { readinessInspectorSheet = nil }
          .padding(12)
      }
      .environment(\.publishReadinessNavigationRequest, request)
      .frame(width: 460, height: 620)
    } else {
      Text("文章已不存在。")
        .padding(24)
    }
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
    case .standardInspector:
      return .expanded
    }
  }

  private func applyResponsiveLayout(_ snapshot: WorkspaceResponsiveLayoutSnapshot) {
    guard snapshot != responsiveLayout else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      responsiveLayout = snapshot
      if !snapshot.canManuallyRevealInspector(for: windowSession.selectedSection) {
        revealsInspectorInCompactWorkspace = false
      }
    }
  }

  private var allowsInspectorInCurrentLayout: Bool {
    allowsInspectorByWidth
      || (canOverrideInspectorInCurrentLayout && revealsInspectorInCompactWorkspace)
  }

  private var allowsInspectorByWidth: Bool {
    return responsiveLayout.allowsStandardInspector
  }

  private var canOverrideInspectorInCurrentLayout: Bool {
    responsiveLayout.canManuallyRevealInspector(for: windowSession.selectedSection)
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

    dismissPublishDrawerIfNeeded()
    return true
  }

  private func dismissPublishDrawerIfNeeded() {
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
    isFocusMode.toggle()
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
