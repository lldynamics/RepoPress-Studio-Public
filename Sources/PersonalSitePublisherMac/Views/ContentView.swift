import AppKit
import PublishingWorkbenchCore
import SwiftUI
#if DEBUG
import PublishingWorkbenchScreenshotSupport
#endif

struct ContentView: View {
  let store: WorkbenchStore
  @ObservedObject private var shellState: WorkbenchShellFeatureFacade
  @Environment(\.openWindow) private var openWindow
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
      VStack(spacing: 0) {
        WorkspaceTopBar(
          store: store,
          isCompact: compactLayout
        )
        Divider()
        WorkspaceShellSplitLayout(
          store: store,
          isCompact: compactLayout,
          isInspectorPresented: shellState.isInspectorPresented,
          contentHealthFilter: $contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      ToolbarItemGroup(placement: .primaryAction) {
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

        Button {
          store.runPreflight()
          store.selectSection(.contentHealth)
        } label: {
          Label("检查", systemImage: "checklist")
        }
        .disabled(!shellState.canUseProtectedWorkbench)

        Button {
          openPublishDrawer(message: nil)
        } label: {
          Label("发布", systemImage: "paperplane")
        }
        .disabled(!shellState.canUseProtectedWorkbench || shellState.selectedDraftID == nil)

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

      ToolbarItem(placement: .secondaryAction) {
        Menu {
          Button {
            if let draftID = shellState.selectedDraftID {
              openWindow(value: draftID)
            }
          } label: {
            Label("在新窗口编辑", systemImage: "macwindow.badge.plus")
          }
          .disabled(shellState.selectedDraftID == nil)

          Button {
            openRepositoryScan()
          } label: {
            Label("扫描仓库", systemImage: "externaldrive")
          }
          .disabled(shellState.isRepositoryScanning)

          Divider()

          Button {
            store.lockPrivacy(reason: "已手动显示隐私界面遮罩。")
          } label: {
            Label("显示隐私遮罩", systemImage: "eye.slash")
          }
          .disabled(shellState.isPrivacyLocked)

          Divider()

          Button {
            isFirstRunSetupPresented = true
          } label: {
            Label("首次设置…", systemImage: "wand.and.stars")
          }
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
    .onChange(of: scenePhase) { _, newValue in
      if newValue != .active {
        store.lockPrivacyIfNeededForInactiveScene()
      }
    }
    .onChange(of: shellState.isPrivacyLocked) { _, isLocked in
      if isLocked {
        isPublishDrawerPresented = false
      }
    }
    .onReceive(repositoryAutoSyncTimer, perform: handleRepositoryAutoSyncTick)
    .alert(
      "工作台数据恢复",
      isPresented: Binding(
        get: { shellState.persistenceRecoveryMessage != nil },
        set: { if !$0 { store.dismissPersistenceRecoveryMessage() } }
      )
    ) {
      Button("继续") {
        store.dismissPersistenceRecoveryMessage()
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

  private func openRepositoryScan() {
    store.selectSection(.sync)
    Task {
      await store.repository.scanAsync()
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
  @ObservedObject var store: WorkbenchStore
  @State private var announcedStatus: WorkbenchAccessibilityStatus?

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
    if store.isPrivacyLocked { return .privacyLocked }
    if store.repositoryScanState.isScanning { return .repositoryScanning(store.repositoryScanState.message) }
    if store.isRemoteRepositoryPublishing { return .remotePublishing }
    if store.isAIChatRunning { return .aiReplying }
    if store.isDeploymentStatusChecking { return .deploymentChecking }
    if let error = store.lastSaveError?.nilIfEmpty { return .saveFailed(error) }
    return .saveStatus(store.lastSaveStatus)
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
