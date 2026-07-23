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

private struct WorkspaceResponsiveLayoutSnapshot: Equatable {
  let width: CGFloat
  let editorDisplayMode: EditorDisplayMode

  static let initial = WorkspaceResponsiveLayoutSnapshot(
    width: WorkbenchLayoutMode.expandedWorkspaceWidth,
    editorDisplayMode: .edit
  )
}

struct ContentView: View {
  let store: WorkbenchStore
  @ObservedObject private var shellState: WorkbenchShellFeatureFacade
  @ObservedObject private var presentationState: WorkbenchContentPresentationFeatureFacade
  @Environment(\.openSettings) private var openSettings
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage("didCompleteFirstRunSetup") private var didCompleteFirstRunSetup = false
  @SceneStorage("workspace.focusMode") private var isFocusMode = false
  @SceneStorage("workspace.revealSidebarInNarrowSplit") private var revealsSidebarInNarrowSplit = false
  @SceneStorage("workspace.revealInspectorInNarrowSplit") private var revealsInspectorInNarrowSplit = false
  @State private var didApplyInitialWorkbenchPreferences = false
  @State private var didApplyScreenshotDemoSurface = false
  @State private var didOpenAIAssistantByDefault = false
  @State private var isRefreshingExternallyCreatedDrafts = false
  @State private var isPublishDrawerPresented = false
  @State private var isFirstRunSetupPresented = false
  @State private var isCommandPalettePresented = false
  @State private var isDraftFullTextSearchPresented = false
  @State private var responsiveLayout = WorkspaceResponsiveLayoutSnapshot.initial
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var imageWorkbenchContextStage: ImageWorkbenchContextStage = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  @StateObject private var repositorySourceSession: RepositoryHTMLSourceSession
  private let repositoryAutoSyncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  init(store: WorkbenchStore) {
    self.store = store
    _shellState = ObservedObject(wrappedValue: store.shell)
    _presentationState = ObservedObject(wrappedValue: store.contentPresentation)
    _repositorySourceSession = StateObject(wrappedValue: RepositoryHTMLSourceSession())
  }

  var body: some View {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    let _ = ContentViewBodyPerformanceProbe.record()
#endif
    GeometryReader { geometry in
      let compactLayout = WorkbenchLayoutMode.isCompact(width: geometry.size.width)
      let responsiveLayoutSnapshot = WorkspaceResponsiveLayoutSnapshot(
        width: geometry.size.width,
        editorDisplayMode: presentationState.editorDisplayMode
      )
      let isInspectorVisible = inspectorPresentation.wrappedValue

      ZStack {
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
          onSelectSection: { store.selectSection($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: inspectorPresentation) {
          MetadataColumn(
            store: store,
            repositoryContextStage: repositoryContextStage,
            repositorySourceSession: repositorySourceSession,
            prioritizesChecks: compactLayout
          )
            .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
        }
        .disabled(shellState.isPrivacyLocked)
        .accessibilityHidden(shellState.isPrivacyLocked)

#if (DEBUG || SCREENSHOT_CAPTURE_BUILD) && !APP_STORE_BUILD
        if usesInlineAIScreenshotInspector {
          ScreenshotInlineAIInspector(
            store: store,
            width: min(max(geometry.size.width * 0.40, 420), 480)
          )
          .zIndex(1)
        }
#endif

        if shellState.isPrivacyLocked {
          PrivacyLockOverlay(store: store)
            .zIndex(2)
        }
      }
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
    .focusedSceneValue(
      \.publishDrawerCommandAction,
      PublishDrawerCommandAction { message in
        openPublishDrawer(message: message)
      }
    )
    .focusedSceneValue(
      \.workspaceCommandPaletteAction,
      WorkspaceCommandPaletteAction {
        guard shellState.canUseProtectedWorkbench else { return }
        isCommandPalettePresented = true
      }
    )
    .focusedSceneValue(
      \.draftFullTextSearchAction,
      DraftFullTextSearchAction(open: openDraftFullTextSearch)
    )
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        WorkspaceToolbarLeadingContent(
          store: store,
          isCompact: isCompactLayout
        )
        .disabled(!shellState.canUseProtectedWorkbench)
        .accessibilityHidden(shellState.isPrivacyLocked)

        PublishingStatusToolbarControl(
          store: store,
          canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
          selectedDraftID: shellState.selectedDraftID,
          openPublishFlow: { openPublishDrawer(message: nil) },
          openRepositoryOverview: {
            repositoryContextStage = .overview
            store.selectSection(.sync)
          },
          openContentHealthOverview: {
            contentHealthFilter = .overview
            store.selectSection(.contentHealth)
          },
          openReleaseHistory: {
            repositoryContextStage = .history
            store.selectSection(.sync)
          }
        )

        workspaceToolbarActionCluster
      }
    }
    .background(
      MainWindowInitialSizeBridge(
        sourceSession: repositorySourceSession,
        profileProvider: { store.activeProfile }
      )
    )
    .focusedSceneValue(
      \.repositorySourceSessionCommandActions,
      RepositorySourceSessionCommandActions(
        hasUnsavedChanges: repositorySourceSession.hasUnsavedChanges,
        save: {
          repositorySourceSession.saveSynchronously(profile: store.activeProfile)
        },
        lastErrorMessage: { repositorySourceSession.errorMessage }
      )
    )
    .onAppear {
      applyWorkbenchPreferences()
      RepositoryHTMLSourceSessionRegistry.shared.register(
        session: repositorySourceSession,
        profileProvider: { store.activeProfile }
      )
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(newValue)
    }
    .onChange(of: shellState.isPrivacyLocked) { _, isLocked in
      if isLocked {
        isPublishDrawerPresented = false
        isFirstRunSetupPresented = false
        isCommandPalettePresented = false
        isDraftFullTextSearchPresented = false
      } else {
        refreshExternallyCreatedDrafts()
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      refreshExternallyCreatedDrafts()
    }
    .onChange(of: shellState.selectedSection) { _, section in
      normalizeWorkspacePresentation(for: section)
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
    .onReceive(repositoryAutoSyncTimer, perform: handleRepositoryAutoSyncTick)
    .alert(
      "工作台数据恢复",
      isPresented: Binding(
        get: { shellState.persistenceRecoveryMessage != nil },
        set: {
          if !$0 && !shellState.isPersistenceRecoveryWriteProtected {
            store.dismissPersistenceRecoveryMessage()
          }
        }
      )
    ) {
      if shellState.isPersistenceRecoveryWriteProtected {
        Button(String(localized: "恢复其他备份…")) {
          guard let sourceURL = WorkbenchRecoverySelectionPanel.chooseSnapshot() else { return }
          if store.installPersistenceRecoverySnapshot(from: sourceURL) {
            NSApp.terminate(nil)
          }
        }
        Button(String(localized: "导出故障文件…")) {
          guard let directoryURL = WorkbenchRecoverySelectionPanel.chooseExportDirectory() else { return }
          _ = store.exportPersistenceRecoveryFiles(to: directoryURL)
        }
        Button(String(localized: "重置为空白工作台"), role: .destructive) {
          _ = store.resetPersistenceAfterUnrecoverableSnapshot()
        }
      } else {
        Button("继续") {
          store.dismissPersistenceRecoveryMessage()
        }
      }
    } message: {
      Text(persistenceRecoveryMessage)
    }
    .sheet(isPresented: $isPublishDrawerPresented) {
      PublishDrawerView(publishingFacade: store.publishing, store: store, isPresented: $isPublishDrawerPresented)
        .frame(minWidth: 680, idealWidth: 780, minHeight: 600, idealHeight: 720)
    }
    .sheet(isPresented: $isFirstRunSetupPresented) {
      FirstRunSetupView(
        store: store,
        finish: finishFirstRunSetup,
        skip: skipFirstRunSetup
      )
    }
    .sheet(isPresented: $isCommandPalettePresented) {
      WorkspaceCommandPalette(store: store, onToggleFocusMode: toggleFocusMode)
    }
    .sheet(isPresented: $isDraftFullTextSearchPresented) {
      DraftFullTextSearchPanel(store: store)
    }
  }

#if (DEBUG || SCREENSHOT_CAPTURE_BUILD) && !APP_STORE_BUILD
  private var usesInlineAIScreenshotInspector: Bool {
    ScreenshotDemoDataService.isEnabledFromEnvironment
      && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .aiChat
  }
#endif

  private func handleRepositoryAutoSyncTick(_ date: Date) {
    guard scenePhase == .active else { return }
    store.refreshDailyFreeUsageIfNeeded(now: date)
    Task {
      await store.tickRepositoryAndDeploymentPolling(now: date)
    }
  }

  private func openDraftFullTextSearch() {
    guard shellState.canUseProtectedWorkbench else { return }
    store.flushDraftBodyEditorBuffers()
    isDraftFullTextSearchPresented = true
  }

  private func applyWorkbenchPreferences() {
    if !didApplyInitialWorkbenchPreferences {
      if scanRepositoryOnLaunch {
        Task {
          await store.repository.scanAsync()
        }
      }
      refreshExternallyCreatedDrafts()
      didApplyInitialWorkbenchPreferences = true
    }
    if !didApplyScreenshotDemoSurface {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
      if ScreenshotDemoDataService.isEnabledFromEnvironment {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          var transaction = Transaction(animation: nil)
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
          }
          ScreenshotDemoSettingsPresenter.openSettingsIfNeeded {
            openSettings()
          }
        }
      } else {
        ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      }
#endif
      didApplyScreenshotDemoSurface = true
    }
    store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    normalizeWorkspacePresentation(for: shellState.selectedSection)
    openAIAssistantByDefaultIfNeeded()
    presentFirstRunSetupIfNeeded()
  }

  private func refreshExternallyCreatedDrafts() {
    guard shellState.canUseProtectedWorkbench,
          !isRefreshingExternallyCreatedDrafts else { return }
    isRefreshingExternallyCreatedDrafts = true
    Task { @MainActor in
      defer { isRefreshingExternallyCreatedDrafts = false }
      _ = await store.importMissingDraftsFromLocalRepository()
    }
  }

  private func presentFirstRunSetupIfNeeded() {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    let isScreenshotDemo = ScreenshotDemoDataService.isEnabledFromEnvironment
#else
    let isScreenshotDemo = false
#endif
    if !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      didCompleteFirstRunSetup = true
    }
    guard WorkbenchFirstRunSetupPolicy.shouldPresent(
      didCompleteSetup: didCompleteFirstRunSetup,
      profile: store.activeProfile,
      isScreenshotDemo: isScreenshotDemo
    ) else { return }
    isFirstRunSetupPresented = true
  }

  private func finishFirstRunSetup() {
    didCompleteFirstRunSetup = true
    isFirstRunSetupPresented = false
    store.selectSection(.sync)
    Task {
      await store.repository.scanAsync()
    }
  }

  private func skipFirstRunSetup() {
    isFirstRunSetupPresented = false
  }

  private var persistenceRecoveryMessage: String {
    shellState.persistenceRecoveryMessage ?? ""
  }

  private var showsDraftEditingToolbar: Bool {
    shellState.selectedSection == .writing
  }

  private var workspaceToolbarActionCluster: some View {
    HStack(spacing: 2) {
      if showsDraftEditingToolbar {
        Button(action: openDraftFullTextSearch) {
          Label("跨文章搜索", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(WorkspaceToolbarIconButtonStyle(isActive: false))
        .disabled(!shellState.canUseProtectedWorkbench)
        .help("跨文章全文搜索（⌥⌘F）")
        .accessibilityLabel("跨文章全文搜索")
        .accessibilityIdentifier("workspace-full-text-search")
      }

      if DistributionFeaturePolicy.allowsExternalAIProviders,
         showsDraftEditingToolbar,
         !effectiveFocusMode {
        aiToolbarButton
      }

      if supportsInspector {
        inspectorToolbarButton
      }

      workspaceMoreToolbarMenu
    }
  }

  private var aiToolbarButton: some View {
    Button(action: toggleAIAssistant) {
      Label(
        "AI",
        systemImage: isAIAssistantVisible
          ? "bubble.left.and.text.bubble.right.fill"
          : "bubble.left.and.text.bubble.right"
      )
    }
    .buttonStyle(WorkspaceToolbarIconButtonStyle(isActive: isAIAssistantVisible))
    .disabled(!shellState.canUseProtectedWorkbench || !canRequestInspectorInCurrentLayout)
    .help(aiToolbarHelp)
    .accessibilityLabel(isAIAssistantVisible ? "关闭 AI 对话" : "打开 AI 对话")
    .accessibilityValue(isAIAssistantVisible ? "已打开" : "已关闭")
    .accessibilityIdentifier("workspace-ai-chat-toggle")
  }

  private var inspectorToolbarButton: some View {
    Button(action: toggleArticleInspector) {
      Label("Inspector", systemImage: "sidebar.right")
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: inspectorPresentation.wrappedValue && !presentationState.isAssistantPresented
      )
    )
    .disabled(!shellState.canUseProtectedWorkbench || !canRequestInspectorInCurrentLayout)
    .help(inspectorToolbarHelp)
    .accessibilityLabel("工作区 Inspector")
    .accessibilityValue(inspectorAccessibilityValue)
    .accessibilityIdentifier("workspace-inspector-toggle")
  }

  private var inspectorToolbarHelp: String {
    if canOverrideSplitInspector && !allowsInspectorInCurrentLayout {
      return "分屏空间较窄；点击仍显示 Inspector"
    }
    guard allowsInspectorInCurrentLayout else {
      return "扩大窗口后可使用 Inspector"
    }
    if presentationState.isAssistantPresented {
      return "切换到文章 Inspector"
    }
    return shellState.isInspectorPresented ? "隐藏 Inspector" : "显示 Inspector"
  }

  private var aiToolbarHelp: String {
    if canOverrideSplitInspector && !allowsInspectorInCurrentLayout {
      return "分屏空间较窄；点击仍打开 AI 对话"
    }
    guard allowsInspectorInCurrentLayout else {
      return "扩大窗口后可使用 AI 对话"
    }
    return isAIAssistantVisible ? "关闭 AI 对话（⌥⌘A）" : "打开 AI 对话（⌥⌘A）"
  }

  private var workspaceMoreToolbarMenu: some View {
    Menu {
      if showsDraftEditingToolbar {
        Button(action: toggleFocusMode) {
          Label(
            effectiveFocusMode ? "显示文章列表" : "专注写作",
            systemImage: effectiveFocusMode
              ? "arrow.down.right.and.arrow.up.left"
              : "arrow.up.left.and.arrow.down.right"
          )
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!shellState.canUseProtectedWorkbench)
        .accessibilityValue(effectiveFocusMode ? "文章列表已隐藏" : "文章列表已显示")
        .accessibilityIdentifier("workspace-focus-mode-toggle")
      }

      if showsDraftEditingToolbar {
        Divider()
      }

      Button {
        store.lockPrivacy(reason: "已手动快速隐藏工作台内容。")
      } label: {
        Label("快速隐藏", systemImage: "eye.slash")
      }
      .disabled(shellState.isPrivacyLocked)

      Divider()

      AdvancedWorkspaceMenu(
        store: store,
        canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
        isFirstRunSetupComplete: didCompleteFirstRunSetup,
        presentFirstRunSetup: { isFirstRunSetupPresented = true }
      )
    } label: {
      WorkspaceToolbarMenuLabel(
        title: "更多",
        systemImage: "ellipsis",
        showsTitle: false
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("专注写作与高级操作")
    .accessibilityIdentifier("workspace-more-menu")
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(
      for: shellState.selectedSection,
      isAIAssistantPresented: DistributionFeaturePolicy.allowsExternalAIProviders
        && presentationState.isAssistantPresented,
      isRepositoryHistoryPresented: repositoryContextStage == .history,
      isMaintenancePresented: contentHealthFilter == .maintenance
    )
  }

  private var inspectorAccessibilityValue: String {
    if canOverrideSplitInspector && !allowsInspectorInCurrentLayout {
      return "分屏空间较窄，已临时隐藏；可以手动显示"
    }
    guard allowsInspectorInCurrentLayout else {
      return "窗口过窄，已临时隐藏"
    }
    if presentationState.isAssistantPresented {
      return "AI 助手已显示"
    }
    return shellState.isInspectorPresented ? "已显示" : "已隐藏"
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

  private var isAIAssistantVisible: Bool {
    DistributionFeaturePolicy.allowsExternalAIProviders
      && presentationState.isAssistantPresented
      && inspectorPresentation.wrappedValue
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
    case .maintenance:
      contentHealthFilter = .maintenance
      hideInspectorIfNeeded()
      store.selectSection(.contentHealth)
    case .releaseHistory:
      repositoryContextStage = .history
      hideInspectorIfNeeded()
      store.selectSection(.sync)
    case .siteStarter:
      break
    case .sync, .images, .contentHealth:
      hideInspectorIfNeeded()
    case .writing, .library:
      break
    }
  }

  private func openAIInspector() {
    guard DistributionFeaturePolicy.allowsExternalAIProviders else { return }
    guard prepareInspectorForUserRequest() else { return }
    guard let draft = store.ensureEditableDraftSelected() else { return }
    guard store.openAIChatWorkspace(for: draft.id) else { return }
    store.setInspectorPresented(true)
  }

  private func openAIAssistantByDefaultIfNeeded() {
    guard !didOpenAIAssistantByDefault else { return }
    didOpenAIAssistantByDefault = true
    guard DistributionFeaturePolicy.allowsExternalAIProviders else {
      if presentationState.isAssistantPresented {
        presentationState.hideAssistant()
      }
      return
    }
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    guard !ScreenshotDemoDataService.isEnabledFromEnvironment else { return }
#endif
    guard shellState.selectedSection == .writing,
          !effectiveFocusMode,
          !isCompactLayout,
          allowsInspectorByWidth,
          shellState.canUseProtectedWorkbench else { return }
    openAIInspector()
  }

  private func toggleAIAssistant() {
    if isAIAssistantVisible {
      presentationState.closeAssistantPanel()
      return
    }
    openAIInspector()
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
    isPublishDrawerPresented = true
    store.setPublishActionMessage(message ?? "发布流程已打开，请选择保存到本地或发布上线。")
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

  private func automaticallyHidesSidebarForSplit(_ snapshot: WorkspaceResponsiveLayoutSnapshot) -> Bool {
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

#if (DEBUG || SCREENSHOT_CAPTURE_BUILD) && !APP_STORE_BUILD
private struct ScreenshotInlineAIInspector: View {
  let store: WorkbenchStore
  let width: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      Divider()
      AIChatContextInspectorView(store: store)
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
    if activityStatus.isPrivacyLocked { return .privacyLocked }
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
  case privacyLocked
  case repositoryScanning(String)
  case remotePublishing
  case aiReplying
  case deploymentChecking
  case saveFailed(String)
  case saveStatus(String)

  var message: String {
    switch self {
    case .privacyLocked: return String(localized: "隐私界面遮罩已启用。")
    case let .repositoryScanning(message):
      return String(format: String(localized: "仓库状态更新：%@"), message)
    case .remotePublishing: return String(localized: "正在执行线上发布。")
    case .aiReplying: return String(localized: "AI 正在回复。")
    case .deploymentChecking: return String(localized: "正在检查部署状态。")
    case let .saveFailed(error):
      return String(format: String(localized: "保存失败：%@"), error)
    case let .saveStatus(status):
      return String(format: String(localized: "保存状态：%@"), status)
    }
  }
}
