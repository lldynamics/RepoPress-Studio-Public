import AppKit
import PublishingWorkbenchCore
import SwiftUI
#if DEBUG
import PublishingWorkbenchScreenshotSupport
#endif

struct ContentView: View {
  let store: WorkbenchStore
  @ObservedObject private var shellState: WorkbenchShellFeatureFacade
  @ObservedObject private var aiState: WorkbenchAIFeatureFacade
  @ObservedObject private var publishingState: WorkbenchPublishingFeatureFacade
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage("didCompleteFirstRunSetup") private var didCompleteFirstRunSetup = false
  @SceneStorage("workspace.focusMode") private var isFocusMode = false
  @State private var didApplyInitialWorkbenchPreferences = false
  @State private var didApplyScreenshotDemoSurface = false
  @State private var isPublishDrawerPresented = false
  @State private var isFirstRunSetupPresented = false
  @State private var isCompactLayout = false
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  private let repositoryAutoSyncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  init(store: WorkbenchStore) {
    self.store = store
    _shellState = ObservedObject(wrappedValue: store.shell)
    _aiState = ObservedObject(wrappedValue: store.ai)
    _publishingState = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    GeometryReader { geometry in
      let compactLayout = WorkbenchLayoutMode.isCompact(width: geometry.size.width)

      ZStack {
        WorkspaceShellSplitLayout(
          store: store,
          isCompact: compactLayout,
          isFocusMode: isFocusMode,
          contentHealthFilter: $contentHealthFilter,
          repositoryContextStage: $repositoryContextStage,
          onSelectSection: { store.selectSection($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: inspectorPresentation) {
          MetadataColumn(store: store, prioritizesChecks: compactLayout)
            .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
        }
        .disabled(shellState.isPrivacyLocked)
        .accessibilityHidden(shellState.isPrivacyLocked)

        if shellState.isPrivacyLocked {
          PrivacyLockOverlay(store: store)
            .zIndex(2)
        }
      }
      .onAppear {
        updateCompactLayout(for: geometry.size.width)
        adaptWorkspacePresentation(
          for: publishingState.editorDisplayMode,
          width: geometry.size.width
        )
      }
      .onChange(of: geometry.size.width) { _, width in
        updateCompactLayout(for: width)
        adaptWorkspacePresentation(for: publishingState.editorDisplayMode, width: width)
      }
      .onReceive(publishingState.editorDisplayModePublisher) { mode in
        adaptWorkspacePresentation(for: mode, width: geometry.size.width)
      }
    }
    .navigationTitle(shellState.activeProfileName)
    .background(WorkbenchAccessibilityStatusAnnouncer(store: store))
    .focusedSceneValue(
      \.publishDrawerCommandAction,
      PublishDrawerCommandAction { message in
        openPublishDrawer(message: message)
      }
    )
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        WorkspaceToolbarLeadingContent(
          store: store,
          isCompact: isCompactLayout
        )
        .disabled(!shellState.canUseProtectedWorkbench)
        .accessibilityHidden(shellState.isPrivacyLocked)
      }

      ToolbarItem(placement: .principal) {
        WorkspaceToolbarTitle(store: store)
        .accessibilityHidden(shellState.isPrivacyLocked)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        if showsDraftEditingToolbar {
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

          Button(action: toggleFocusMode) {
            Label(
              isFocusMode ? "退出专注" : "专注写作",
              systemImage: isFocusMode
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
            )
          }
          .keyboardShortcut("f", modifiers: [.command, .shift])
          .disabled(!shellState.canUseProtectedWorkbench)
          .help(isFocusMode ? "退出专注写作（⇧⌘F）" : "专注写作（⇧⌘F）")
          .accessibilityLabel(isFocusMode ? "退出专注写作" : "进入专注写作")
          .accessibilityValue(isFocusMode ? "已开启" : "已关闭")
          .accessibilityIdentifier("workspace-focus-mode-toggle")
        }

        if supportsInspector && !isFocusMode {
          Button(action: toggleArticleInspector) {
            Label("Inspector", systemImage: "sidebar.right")
          }
          .disabled(!shellState.canUseProtectedWorkbench)
          .help(inspectorToggleHelp)
          .accessibilityLabel("工作区 Inspector")
          .accessibilityValue(inspectorAccessibilityValue)
          .accessibilityIdentifier("workspace-inspector-toggle")
        }
      }

      ToolbarItem(placement: .secondaryAction) {
        Menu {
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
            showsFirstRunSetup: !didCompleteFirstRunSetup,
            presentFirstRunSetup: { isFirstRunSetupPresented = true }
          )
        } label: {
          Label("更多", systemImage: "ellipsis.circle")
        }
      }
    }
    .onAppear {
      applyWorkbenchPreferences()
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(newValue)
    }
    .onChange(of: shellState.isPrivacyLocked) { _, isLocked in
      if isLocked {
        isPublishDrawerPresented = false
      }
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
      PublishDrawerView(store: store, isPresented: $isPublishDrawerPresented)
        .frame(minWidth: 680, idealWidth: 780, minHeight: 600, idealHeight: 720)
    }
    .sheet(isPresented: $isFirstRunSetupPresented) {
      FirstRunSetupView(
        store: store,
        finish: finishFirstRunSetup,
        skip: skipFirstRunSetup
      )
    }
  }

  private func handleRepositoryAutoSyncTick(_ date: Date) {
    guard scenePhase == .active else { return }
    Task {
      await store.tickRepositoryAndDeploymentPolling(now: date)
    }
  }

  private func applyWorkbenchPreferences() {
    if !didApplyInitialWorkbenchPreferences {
      if scanRepositoryOnLaunch {
        Task {
          await store.repository.scanAsync()
        }
      }
      didApplyInitialWorkbenchPreferences = true
    }
    if !didApplyScreenshotDemoSurface {
#if DEBUG
      ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      ScreenshotDemoSettingsPresenter.openSettingsIfNeeded()
#endif
      didApplyScreenshotDemoSurface = true
    }
    store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    normalizeWorkspacePresentation(for: shellState.selectedSection)
    presentFirstRunSetupIfNeeded()
  }

  private func presentFirstRunSetupIfNeeded() {
#if DEBUG
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
    didCompleteFirstRunSetup = true
    isFirstRunSetupPresented = false
  }

  private var persistenceRecoveryMessage: String {
    shellState.persistenceRecoveryMessage ?? ""
  }

  private var showsDraftEditingToolbar: Bool {
    shellState.selectedSection == .writing
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(
      for: shellState.selectedSection,
      isAIAssistantPresented: aiState.isAssistantPresented,
      isRepositoryHistoryPresented: repositoryContextStage == .history,
      isMaintenancePresented: contentHealthFilter == .maintenance
    )
  }

  private var inspectorToggleHelp: String {
    if aiState.isAssistantPresented {
      return "切换到文章 Inspector"
    }
    return shellState.isInspectorPresented ? "隐藏 Inspector" : "显示 Inspector"
  }

  private var inspectorAccessibilityValue: String {
    if aiState.isAssistantPresented {
      return "AI 助手已显示"
    }
    return shellState.isInspectorPresented ? "已显示" : "已隐藏"
  }

  private var inspectorPresentation: Binding<Bool> {
    Binding(
      get: { shellState.isInspectorPresented && supportsInspector && !isFocusMode },
      set: { store.setInspectorPresented($0) }
    )
  }

  private func normalizeWorkspacePresentation(for section: WorkspaceSection) {
    if section != .writing {
      isFocusMode = false
    }
    if section != .writing && aiState.isAssistantPresented {
      aiState.hideAssistant()
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
    case .siteStarter, .generalDrafts:
      break
    case .writing, .sync, .images, .contentHealth:
      break
    }
  }

  private func openAIInspector() {
    guard let draft = store.ensureEditableDraftSelected() else { return }
    guard store.openAIChatWorkspace(for: draft.id) else { return }
    store.setInspectorPresented(true)
  }

  private func toggleArticleInspector() {
    if isFocusMode {
      isFocusMode = false
      if aiState.isAssistantPresented {
        aiState.hideAssistant()
      }
      if !shellState.isInspectorPresented {
        store.setInspectorPresented(true)
      }
      return
    }

    if aiState.isAssistantPresented {
      aiState.hideAssistant()
      if !shellState.isInspectorPresented {
        store.setInspectorPresented(true)
      }
      return
    }

    store.setInspectorPresented(!shellState.isInspectorPresented)
  }

  private func hideInspectorIfNeeded() {
    if aiState.isAssistantPresented {
      aiState.hideAssistant()
    }
    if shellState.isInspectorPresented {
      store.setInspectorPresented(false)
    }
  }

  private func openPublishDrawer(message: String?) {
    store.ensureEditableDraftSelected()
    store.runPreflight()
    isPublishDrawerPresented = true
    store.setPublishActionMessage(message ?? "发布流程已打开，请按检查、Diff、写入、远端和部署步骤确认。")
  }

  private func updateCompactLayout(for width: CGFloat) {
    let isNowCompact = WorkbenchLayoutMode.isCompact(width: width)
    guard isNowCompact != isCompactLayout else { return }
    isCompactLayout = isNowCompact
  }

  private func toggleFocusMode() {
    guard shellState.selectedSection == .writing else { return }
    isFocusMode.toggle()
  }

  private func adaptWorkspacePresentation(for mode: EditorDisplayMode, width: CGFloat) {
    guard !isFocusMode else { return }
    guard WorkbenchLayoutMode.shouldAutoHideAuxiliaryPanels(
      editorDisplayMode: mode,
      width: width
    ) else { return }

    if aiState.isAssistantPresented {
      aiState.hideAssistant()
    }
    if shellState.isInspectorPresented {
      store.setInspectorPresented(false)
    }
  }
}

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
    case .privacyLocked: return "隐私界面遮罩已启用。"
    case let .repositoryScanning(message): return "仓库状态更新：\(message)"
    case .remotePublishing: return "正在执行线上发布。"
    case .aiReplying: return "AI 正在回复。"
    case .deploymentChecking: return "正在检查部署状态。"
    case let .saveFailed(error): return "保存失败：\(error)"
    case let .saveStatus(status): return "保存状态：\(status)"
    }
  }
}
