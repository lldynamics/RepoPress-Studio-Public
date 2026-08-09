import AppKit
import PublishingWorkbenchCore
import SwiftUI

@main
struct PersonalSitePublisherMacApp: App {
  @NSApplicationDelegateAdaptor(PersonalSitePublisherMacAppDelegate.self) private var appDelegate
  @StateObject private var launchCoordinator: WorkbenchLaunchCoordinator
  @StateObject private var appUpdateController = AppUpdateController()
  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue

  init() {
    AppLanguagePreference.prepareForLaunch()
    // Earlier builds disabled AppKit restoration globally. Remove those sticky
    // overrides now that the main workspace is owned by a native SwiftUI scene.
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    // Deterministic screenshot and XCUI launches pass temporary restoration
    // overrides on the command line. Keep those volatile values for the
    // automated run so AppKit cannot reopen a stale workspace window while the
    // requested demo surface is being installed.
    if ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"] != "1" {
      UserDefaults.standard.removeObject(forKey: "ApplePersistenceIgnoreState")
      UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
    }
#else
    UserDefaults.standard.removeObject(forKey: "ApplePersistenceIgnoreState")
    UserDefaults.standard.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
#endif
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if ScreenshotDemoDataService.isEnabledFromEnvironment {
      let persistence = ScreenshotDemoDataService.preparePersistenceIfEnabled()
      let demoRootURL = persistence.fileURL.deletingLastPathComponent()
      let knowledgeLibraryService = KnowledgeLibraryService(
        rootURL: demoRootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
      )
      _launchCoordinator = StateObject(
        wrappedValue: WorkbenchLaunchCoordinator(
          persistence: persistence,
          knowledgeLibraryService: knowledgeLibraryService,
          rssReaderFileURL: demoRootURL
            .appendingPathComponent("RSSReader", isDirectory: true)
            .appendingPathComponent("reader.sqlite", isDirectory: false),
          managedAttachmentFileStore: ManagedAttachmentFileStore(
            rootDirectoryURL: demoRootURL.appendingPathComponent(
              "ManagedAttachments",
              isDirectory: true
            )
          ),
          workspaceBackupDirectoryURL: demoRootURL.appendingPathComponent(
            WorkspaceBackupService.automaticBackupDirectoryName,
            isDirectory: true
          )
        )
      )
    } else {
      _launchCoordinator = StateObject(wrappedValue: WorkbenchLaunchCoordinator())
    }
#else
    _launchCoordinator = StateObject(wrappedValue: WorkbenchLaunchCoordinator())
#endif
  }

  var body: some Scene {
    WindowGroup("RepoPress Studio", id: "main-workbench") {
      WorkbenchLaunchRootView(
        coordinator: launchCoordinator,
        onReady: { store, browserBridge in
          appDelegate.workbenchStore = store
          appDelegate.browserBridge = browserBridge
        }
      )
        .frame(
          minWidth: WorkbenchLayoutMode.minimumWindowWidth,
          minHeight: WorkbenchLayoutMode.minimumWindowHeight
        )
        .thinRedScrollbars()
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
        .background(ScreenshotCaptureWindowBridge())
#endif
        .background(
          MainWindowOpenActionRegistration { action in
            appDelegate.openMainWindowAction = action
          }
        )
        .tint(selectedAccentPalette.color)
    }
    .defaultSize(
      width: WorkbenchLayoutMode.defaultWindowWidth,
      height: WorkbenchLayoutMode.defaultWindowHeight
    )
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands {
      AppUpdateCommands(controller: appUpdateController)
      if let store = launchCoordinator.store {
        PublishingConsoleCommands(store: store)
      }
    }

    Settings {
      Group {
        if let store = launchCoordinator.store {
          ProtectedSettingsView(
            store: store,
            rssStore: launchCoordinator.rssStore,
            launchCoordinator: launchCoordinator
          )
        } else {
          VStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.plus")
              .font(.title)
              .foregroundStyle(.secondary)
            Text("请先在主窗口完成数据文件夹设置。")
              .foregroundStyle(.secondary)
          }
          .workbenchSettingsWindowSize()
        }
      }
        .tint(selectedAccentPalette.color)
    }
  }

  private var selectedAccentPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }
}

private struct MainWindowOpenActionRegistration: View {
  @Environment(\.openWindow) private var openWindow
  let register: (@escaping () -> Void) -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        register {
          openWindow(id: "main-workbench")
        }
      }
  }
}

@MainActor
final class PersonalSitePublisherMacAppDelegate: NSObject, NSApplicationDelegate {
  var workbenchStore: WorkbenchStore?
  var browserBridge: KnowledgeBrowserBridge?
  var openMainWindowAction: (() -> Void)? {
    didSet {
      guard openMainWindowAction != nil,
            mainWindowRestoreRequestState.actionBecameAvailable()
      else {
        return
      }
      enqueueMainWindowRestoreAfterMenuTracking()
    }
  }

  private let reopenMenuItemIdentifier = NSUserInterfaceItemIdentifier(
    "com.jinfang.repopress-studio.show-main-window"
  )
  private var closingMainWindowIdentifiers = Set<ObjectIdentifier>()
  private var persistentWindowCommandRequestState = PersistentWindowCommandRequestState()
  private var mainWindowRestoreRequestState = MainWindowRestoreRequestState()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
    requestPersistentWindowCommandReconciliation()
    scheduleMainWindowRecoveryIfNeeded()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    requestPersistentWindowCommandReconciliation()
    scheduleMainWindowRecoveryIfNeeded()
  }

  func applicationDidUpdate(_ notification: Notification) {
    // SwiftUI may replace scene-owned menu trees while opening or closing a
    // WindowGroup. Reconcile only through the coalesced default-mode scheduler
    // so updates never mutate AppKit menus during an active tracking session.
    requestPersistentWindowCommandReconciliation()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if sender.windows.contains(where: { window in
      isLiveMainWorkbenchWindow(window) && window.isVisible
    }) {
      return true
    }
    let hasRestorableMainWindow = sender.windows.contains(where: isLiveMainWorkbenchWindow)
    guard hasRestorableMainWindow || openMainWindowAction != nil else {
      return true
    }
    requestMainWindowRestore()
    return false
  }

  @objc
  private func showMainWindow(_ sender: Any?) {
    requestMainWindowRestore()
  }

  @objc
  private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          isMainWorkbenchWindow(window)
    else {
      return
    }
    closingMainWindowIdentifiers.insert(ObjectIdentifier(window))
    // SwiftUI removes scene-scoped command contributions after the last
    // WindowGroup window closes. Recheck across that teardown window while the
    // request state preserves the reconciliation intent until a menu resolves.
    for delay in [0.2, 0.6, 1.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.requestPersistentWindowCommandReconciliation()
      }
    }
  }

  @objc
  private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          isMainWorkbenchWindow(window)
    else {
      return
    }
    closingMainWindowIdentifiers.remove(ObjectIdentifier(window))
    mainWindowRestoreRequestState.markCompleted()
    requestPersistentWindowCommandReconciliation()
  }

  private enum MainWindowRestoreAttempt {
    case restoredExistingWindow
    case dispatchedOpenAction
    case unavailable
  }

  private func restoreMainWindow(in application: NSApplication) -> MainWindowRestoreAttempt {
    if let mainWindow = application.windows.first(where: { window in
      isLiveMainWorkbenchWindow(window)
    }) {
      if mainWindow.isMiniaturized {
        mainWindow.deminiaturize(nil)
      }
      mainWindow.makeKeyAndOrderFront(nil)
      return .restoredExistingWindow
    }
    guard let openMainWindowAction else { return .unavailable }
    openMainWindowAction()
    return .dispatchedOpenAction
  }

  private func scheduleMainWindowRecoveryIfNeeded() {
    // AppKit finishes restoring SwiftUI scene windows after the application
    // delegate launch callbacks. A previously closed or hidden restoration
    // record can therefore leave a healthy process with no visible UI. Wait
    // for that restoration pass, then surface the existing workbench window
    // (or ask the WindowGroup to create one once its open action is ready).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self else { return }
      if !NSApp.windows.contains(where: \.isVisible) {
        self.requestMainWindowRestore()
      }
      self.requestPersistentWindowCommandReconciliation()
    }
  }

  private func requestMainWindowRestore() {
    guard mainWindowRestoreRequestState.request() else { return }
    enqueueMainWindowRestoreAfterMenuTracking()
  }

  private func enqueueMainWindowRestoreAfterMenuTracking() {
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self,
              self.mainWindowRestoreRequestState.beginScheduledAttempt()
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch self.restoreMainWindow(in: NSApp) {
        case .restoredExistingWindow:
          self.mainWindowRestoreRequestState.markCompleted()
        case .dispatchedOpenAction:
          self.mainWindowRestoreRequestState.markActionDispatched()
        case .unavailable:
          self.scheduleMainWindowRestoreRetry(
            self.mainWindowRestoreRequestState.markActionUnavailable()
          )
        }
      }
    }
  }

  private func scheduleMainWindowRestoreRetry(
    _ retry: WindowLifecycleRetrySchedule?
  ) {
    guard let retry else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
      guard let self,
            self.mainWindowRestoreRequestState.retryTimerFired(token: retry.token)
      else { return }
      self.enqueueMainWindowRestoreAfterMenuTracking()
    }
  }

  private func isMainWorkbenchWindow(_ window: NSWindow) -> Bool {
    if let identifier = window.identifier?.rawValue,
       identifier.contains("main-workbench") {
      return true
    }
    return window.title == "RepoPress Studio" || window.title == "RepoPress"
  }

  private func requestPersistentWindowCommandReconciliation() {
    guard persistentWindowCommandRequestState.request() else { return }
    enqueuePersistentWindowCommandReconciliation()
  }

  private func enqueuePersistentWindowCommandReconciliation() {
    // AppKit tracks menus in NSEventTrackingRunLoopMode. Scheduling all menu
    // mutations in the default mode guarantees that this block cannot run
    // while any menu bar or submenu is still being tracked.
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self,
              self.persistentWindowCommandRequestState.beginScheduledAttempt()
        else { return }
        self.reconcilePersistentWindowCommand()
      }
    }
  }

  private func reconcilePersistentWindowCommand() {
    pruneClosedMainWindowIdentifiers()
    guard let windowMenu = resolveWindowMenu() else {
      schedulePersistentWindowCommandReconciliationRetry(
        persistentWindowCommandRequestState.markAttemptUnavailable()
      )
      return
    }
    persistentWindowCommandRequestState.markCompleted()
    normalizeVisibleApplicationName()
    let existingItem = windowMenu.items.first {
      $0.identifier == reopenMenuItemIdentifier
    }
    let decision = PersistentWindowCommandMenuPolicy.decision(
      hasMainWindow: hasOpenMainWorkbenchWindow,
      commandExists: existingItem != nil,
      isMenuTracking: false
    )

    switch decision {
    case .noChange:
      return
    case .deferUntilTrackingEnds:
      return
    case .remove:
      if let existingItem {
        windowMenu.removeItem(existingItem)
      }
      return
    case .install:
      break
    }

    let reopenItem = NSMenuItem(
      title: String(localized: "显示 RepoPress Studio"),
      action: #selector(showMainWindow(_:)),
      keyEquivalent: "0"
    )
    reopenItem.identifier = reopenMenuItemIdentifier
    reopenItem.keyEquivalentModifierMask = [.command]
    reopenItem.target = self
    windowMenu.insertItem(reopenItem, at: 0)
  }

  private func schedulePersistentWindowCommandReconciliationRetry(
    _ retry: WindowLifecycleRetrySchedule?
  ) {
    guard let retry else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
      guard let self,
            self.persistentWindowCommandRequestState.retryTimerFired(token: retry.token)
      else { return }
      self.enqueuePersistentWindowCommandReconciliation()
    }
  }

  private var hasOpenMainWorkbenchWindow: Bool {
    NSApp.windows.contains { window in
      isLiveMainWorkbenchWindow(window) && (window.isVisible || window.isMiniaturized)
    }
  }

  private func isLiveMainWorkbenchWindow(_ window: NSWindow) -> Bool {
    isMainWorkbenchWindow(window)
      && !closingMainWindowIdentifiers.contains(ObjectIdentifier(window))
  }

  private func pruneClosedMainWindowIdentifiers() {
    let knownWindowIdentifiers = Set(NSApp.windows.map(ObjectIdentifier.init))
    closingMainWindowIdentifiers.formIntersection(knownWindowIdentifiers)
  }

  private func resolveWindowMenu() -> NSMenu? {
    if let windowsMenu = NSApp.windowsMenu {
      return windowsMenu
    }
    return NSApp.mainMenu?.items.compactMap(\.submenu).first { menu in
      menu.items.contains {
        $0.action == #selector(NSWindow.performMiniaturize(_:))
      } && menu.items.contains {
        $0.action == #selector(NSWindow.performZoom(_:))
      }
    }
  }

  private func normalizeVisibleApplicationName() {
    guard let applicationMenuItem = NSApp.mainMenu?.items.first else { return }
    if applicationMenuItem.title != "RepoPress Studio" {
      applicationMenuItem.title = "RepoPress Studio"
    }
    if applicationMenuItem.submenu?.title != "RepoPress Studio" {
      applicationMenuItem.submenu?.title = "RepoPress Studio"
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if RepositoryHTMLSourceSessionRegistry.shared.hasUnsavedChanges {
      let alert = NSAlert()
      alert.messageText = String(localized: "HTML 源文件尚未保存")
      alert.informativeText = String(localized: "保存后退出可保留源码更改；也可以返回编辑器继续处理。")
      alert.alertStyle = .warning
      alert.addButton(withTitle: String(localized: "保存并退出"))
      alert.addButton(withTitle: String(localized: "继续编辑")).keyEquivalent = "\u{1b}"
      alert.addButton(withTitle: String(localized: "不保存并退出"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        guard RepositoryHTMLSourceSessionRegistry.shared.saveBeforeTermination() else {
          let failureAlert = NSAlert()
          failureAlert.messageText = String(localized: "未能保存 HTML 源文件")
          failureAlert.informativeText = RepositoryHTMLSourceSessionRegistry.shared.lastErrorMessage
            ?? String(localized: "请返回编辑器检查文件权限或外部修改冲突。")
          failureAlert.alertStyle = .warning
          failureAlert.addButton(withTitle: String(localized: "继续编辑"))
          failureAlert.runModal()
          return .terminateCancel
        }
      case .alertSecondButtonReturn:
        return .terminateCancel
      case .alertThirdButtonReturn:
        break
      default:
        return .terminateCancel
      }
    }

    guard let workbenchStore, !workbenchStore.flushPendingChanges() else {
      return .terminateNow
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "未能保存工作台修改")
    alert.informativeText = workbenchStore.lastSaveError
      ?? String(localized: "请修复保存位置或权限后重试。应用将保持打开，避免丢失未保存修改。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "继续编辑"))
    alert.runModal()
    return .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    browserBridge?.stop()
    workbenchStore?.stopLocalSitePreviewImmediately()
    let didFlush = workbenchStore?.flushPendingChanges() ?? true
    if didFlush {
      WorkbenchSessionRecovery.shared.markCleanExit()
    }
  }

}

private struct ProtectedSettingsView: View {
  @ObservedObject var store: WorkbenchStore
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator

  var body: some View {
    ZStack {
      SettingsView(
        store: store,
        rssStore: rssStore,
        launchCoordinator: launchCoordinator
      )
      .disabled(!store.canUseProtectedWorkbench)
      .disabled(launchCoordinator.phase != .ready)
      .accessibilityHidden(store.isQuickHideActive)

      if store.isQuickHideActive {
        QuickHideOverlay(store: store)
      }
    }
    .settingsThinRedScrollbars()
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    .background(ScreenshotCaptureWindowBridge(role: .settings))
#endif
  }
}
