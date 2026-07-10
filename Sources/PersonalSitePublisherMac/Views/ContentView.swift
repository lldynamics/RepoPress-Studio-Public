import PublishingWorkbenchCore
import SwiftUI

struct ContentView: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @State private var didApplyInitialWorkbenchPreferences = false
  @State private var didApplyScreenshotDemoSurface = false
  @State private var isPublishDrawerPresented = false
  @State private var isCompactLayout = false
  @State private var isCompactInspectorPresented = false
  private let repositoryAutoSyncTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

  var body: some View {
    GeometryReader { geometry in
      let compactLayout = geometry.size.width < 1180

      ZStack {
      VStack(spacing: 0) {
        WorkspaceTopBar(
          store: store,
          isCompact: compactLayout
        )
        Divider()
        HSplitView {
          WorkspaceSidebarColumn(store: store, isCompact: compactLayout)
            .frame(
              minWidth: compactLayout ? 220 : 260,
              idealWidth: compactLayout ? 240 : 300,
              maxWidth: compactLayout ? 300 : 380,
              maxHeight: .infinity
            )

          EditorCenterColumn(store: store)
            .frame(minWidth: compactLayout ? 460 : 560, maxWidth: .infinity, maxHeight: .infinity)

          if store.isInspectorPresented && !compactLayout {
            MetadataColumn(store: store)
              .frame(minWidth: 320, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .disabled(store.isPrivacyLocked)
      .accessibilityHidden(store.isPrivacyLocked)

      if store.isPrivacyLocked {
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
    .navigationTitle(store.activeProfile.name)
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
        .disabled(!store.canUseProtectedWorkbench)

        Button {
          store.save()
        } label: {
          Label("保存", systemImage: "tray.and.arrow.down")
        }
        .disabled(!store.canUseProtectedWorkbench)

        Button {
          store.runPreflight()
          store.selectSection(.contentHealth)
        } label: {
          Label("检查", systemImage: "checklist")
        }
        .disabled(!store.canUseProtectedWorkbench)

        Button {
          openPublishDrawer(message: nil)
        } label: {
          Label("发布", systemImage: "paperplane")
        }
        .disabled(!store.canUseProtectedWorkbench || store.selectedDraft == nil)

        Button {
          if isCompactLayout {
            isCompactInspectorPresented = true
          } else {
            store.setInspectorPresented(!store.isInspectorPresented)
          }
        } label: {
          Label("Inspector", systemImage: "sidebar.right")
        }
        .disabled(!store.canUseProtectedWorkbench)
      }

      ToolbarItem(placement: .secondaryAction) {
        Menu {
          Button {
            if let draftID = store.selectedDraftID {
              openWindow(value: draftID)
            }
          } label: {
            Label("在新窗口编辑", systemImage: "macwindow.badge.plus")
          }
          .disabled(store.selectedDraftID == nil)

          Button {
            store.selectSection(.sync)
            Task {
              await store.repository.scanAsync()
            }
          } label: {
            Label("扫描仓库", systemImage: "externaldrive")
          }
          .disabled(store.repository.scanState.isScanning)

          Divider()

          Button {
            store.lockPrivacy(reason: "已手动显示隐私界面遮罩。")
          } label: {
            Label("显示隐私遮罩", systemImage: "eye.slash")
          }
          .disabled(store.isPrivacyLocked)
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
    .onChange(of: store.isPrivacyLocked) { _, isLocked in
      if isLocked {
        isPublishDrawerPresented = false
      }
    }
    .onReceive(repositoryAutoSyncTimer) { date in
      guard scenePhase == .active else {
        return
      }
      Task {
        await store.tickRepositoryAndDeploymentPolling(now: date)
      }
    }
    .alert(
      "工作台数据恢复",
      isPresented: Binding(
        get: { store.persistenceRecoveryMessage != nil },
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
      MetadataColumn(store: store)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 520, idealHeight: 680)
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
      ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      ScreenshotDemoSettingsPresenter.openSettingsIfNeeded()
      didApplyScreenshotDemoSurface = true
    }
    store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
  }

  private var persistenceRecoveryMessage: String {
    store.persistenceRecoveryMessage ?? ""
  }

  private func openPublishDrawer(message: String?) {
    store.ensureEditableDraftSelected()
    store.runPreflight()
    isPublishDrawerPresented = true
    store.setPublishActionMessage(message ?? "发布流程已打开，请按检查、Diff、写入、远端和部署步骤确认。")
  }

  private func updateCompactLayout(for width: CGFloat) {
    let isNowCompact = width < 1180
    guard isNowCompact != isCompactLayout else { return }
    let wasInspectorVisible = store.isInspectorPresented
    isCompactLayout = isNowCompact
    if isNowCompact, wasInspectorVisible {
      isCompactInspectorPresented = true
    } else if !isNowCompact {
      isCompactInspectorPresented = false
    }
  }
}
