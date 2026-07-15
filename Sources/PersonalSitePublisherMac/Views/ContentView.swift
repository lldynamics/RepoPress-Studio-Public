import AppKit
import PublishingWorkbenchCore
import SwiftUI
#if DEBUG
import PublishingWorkbenchScreenshotSupport
#endif

struct ContentView: View {
  let store: WorkbenchStore
  @ObservedObject private var shellState: WorkbenchShellFeatureFacade
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage("didCompleteFirstRunSetup") private var didCompleteFirstRunSetup = false
  @State private var didApplyInitialWorkbenchPreferences = false
  @State private var didApplyScreenshotDemoSurface = false
  @State private var isPublishDrawerPresented = false
  @State private var isFirstRunSetupPresented = false
  @State private var isCompactLayout = false
  @State private var isCompactInspectorPresented = false
  @State private var contentHealthFilter: ContentHealthContextFilter = .overview
  @State private var repositoryContextStage: RepositoryContextStage = .overview
  private let repositoryAutoSyncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  init(store: WorkbenchStore) {
    self.store = store
    _shellState = ObservedObject(wrappedValue: store.shell)
  }

  var body: some View {
    GeometryReader { geometry in
      let compactLayout = WorkbenchLayoutMode.isCompact(width: geometry.size.width)

      ZStack {
        WorkspaceShellSplitLayout(
          store: store,
          isCompact: compactLayout,
          isInspectorPresented: shellState.isInspectorPresented,
          contentHealthFilter: $contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(shellState.isPrivacyLocked)
        .accessibilityHidden(shellState.isPrivacyLocked)

        if shellState.isPrivacyLocked {
          PrivacyLockOverlay(store: store)
            .zIndex(2)
        }
      }
      .onAppear {
        updateCompactLayout(for: geometry.size.width)
      }
      .onChange(of: geometry.size.width) { _, width in
        updateCompactLayout(for: width)
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
        HStack(spacing: 10) {
          WorkspaceToolbarTitle(store: store)

          if showsDraftEditingToolbar {
            Divider()
              .frame(height: 18)

            Button {
              store.createDraft()
            } label: {
              Label("新建", systemImage: "square.and.pencil")
            }
            .disabled(!shellState.canUseProtectedWorkbench)

            Button {
              store.save()
            } label: {
              Label("保存", systemImage: "tray.and.arrow.down")
            }
            .disabled(!shellState.canUseProtectedWorkbench)

            PublishingStatusToolbarControl(
              store: store,
              canUseProtectedWorkbench: shellState.canUseProtectedWorkbench,
              selectedDraftID: shellState.selectedDraftID,
              openPublishFlow: { openPublishDrawer(message: nil) },
              openReleaseHistory: {
                repositoryContextStage = .history
                store.selectSection(.sync)
              }
            )
          }
        }
        .accessibilityHidden(shellState.isPrivacyLocked)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        if supportsInspector {
          Button {
            if isCompactLayout {
              isCompactInspectorPresented = true
            } else {
              store.setInspectorPresented(!shellState.isInspectorPresented)
            }
          } label: {
            Label("Inspector", systemImage: "sidebar.right")
          }
          .disabled(!shellState.canUseProtectedWorkbench)
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
    .sheet(isPresented: $isCompactInspectorPresented) {
      MetadataColumn(store: store, prioritizesChecks: true)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620, minHeight: 520, idealHeight: 620)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("完成") {
              isCompactInspectorPresented = false
            }
          }
        }
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
    switch shellState.selectedSection {
    case .writing, .images, .ai:
      return true
    case .sync:
      return repositoryContextStage != .history
    case .contentHealth:
      return contentHealthFilter != .maintenance
    case .siteStarter, .generalDrafts, .maintenance, .releaseHistory:
      return false
    }
  }

  private func normalizeWorkspacePresentation(for section: WorkspaceSection) {
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
      hideInspectorIfNeeded()
    case .writing, .sync, .images, .contentHealth, .ai:
      break
    }
  }

  private func hideInspectorIfNeeded() {
    if shellState.isInspectorPresented {
      store.setInspectorPresented(false)
    }
    isCompactInspectorPresented = false
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
    let wasInspectorVisible = shellState.isInspectorPresented
    isCompactLayout = isNowCompact
    if isNowCompact, wasInspectorVisible {
      isCompactInspectorPresented = true
    } else if !isNowCompact {
      isCompactInspectorPresented = false
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
