import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum WorkbenchLaunchPhase: Equatable {
  case preparing(String)
  case needsDataRoot
  case ready
}

@MainActor
final class WorkbenchLaunchCoordinator: ObservableObject {
  @Published private(set) var store: WorkbenchStore?
  @Published private(set) var browserBridge: KnowledgeBrowserBridge?
  @Published private(set) var rssStore: RSSReaderStore?
  @Published private(set) var phase: WorkbenchLaunchPhase
  @Published private(set) var dataRootMessage: String?
  @Published private(set) var canMigrateLegacyData = false
  @Published private(set) var dataRootPath: String?
  @Published private(set) var launchRecoveryChoiceRequired = false
  @Published private(set) var isSafeMode = false

  private let bookmarkStore: WorkbenchDataRootBookmarkStore?
  private let explicitRuntimePaths: WorkbenchRuntimePaths?
  private let sessionRecovery: WorkbenchSessionRecovery
  private var dataRootSession: WorkbenchDataRootSession?
  private var didStart = false
  private var didStartReadyServices = false

  convenience init(
    bookmarkStore: WorkbenchDataRootBookmarkStore = WorkbenchDataRootBookmarkStore(),
    sessionRecovery: WorkbenchSessionRecovery? = nil
  ) {
    self.init(
      bookmarkStore: bookmarkStore,
      explicitRuntimePaths: nil,
      sessionRecovery: sessionRecovery
    )
  }

  convenience init(
    persistence: WorkbenchPersistence,
    knowledgeLibraryService: KnowledgeLibraryService,
    rssReaderFileURL: URL,
    managedAttachmentFileStore: ManagedAttachmentFileStore,
    workspaceBackupDirectoryURL: URL,
    sessionRecovery: WorkbenchSessionRecovery? = nil
  ) {
    self.init(
      bookmarkStore: nil,
      explicitRuntimePaths: WorkbenchRuntimePaths(
        persistence: persistence,
        knowledgeLibraryService: knowledgeLibraryService,
        rssReaderFileURL: rssReaderFileURL,
        managedAttachmentFileStore: managedAttachmentFileStore,
        workspaceBackupDirectoryURL: workspaceBackupDirectoryURL
      ),
      sessionRecovery: sessionRecovery
    )
  }

  private init(
    bookmarkStore: WorkbenchDataRootBookmarkStore?,
    explicitRuntimePaths: WorkbenchRuntimePaths?,
    sessionRecovery: WorkbenchSessionRecovery?
  ) {
    self.bookmarkStore = bookmarkStore
    self.explicitRuntimePaths = explicitRuntimePaths
    let resolvedSessionRecovery = sessionRecovery ?? .shared
    self.sessionRecovery = resolvedSessionRecovery
    self.phase = .preparing(String(localized: "正在检查数据文件夹…"))

    let launchState = resolvedSessionRecovery.beginLaunch(
      safeModeRequestedByEnvironment: Self.safeModeRequestedByProcess
    )
    isSafeMode = launchState.safeModeWasRequested
    launchRecoveryChoiceRequired = launchState.hadUncleanPreviousSession
      && !launchState.safeModeWasRequested
  }

  func start() async {
    guard !didStart, !launchRecoveryChoiceRequired else { return }
    didStart = true

    if let explicitRuntimePaths {
      await prepareRuntime(using: explicitRuntimePaths)
      return
    }
    await openRememberedDataRoot()
  }

  func restoreExistingDataRoot() async {
    guard let selectedURL = await WorkbenchDataRootSelectionPanel.chooseExistingDataRoot() else {
      return
    }
    await restoreExistingDataRoot(at: selectedURL)
  }

  /// Accepts either the data root itself or its containing directory. The
  /// latter is useful after reinstalling the app, when users commonly select
  /// the same external-drive folder they chose during initial setup.
  func restoreExistingDataRoot(at selectedURL: URL) async {
    guard let bookmarkStore else { return }

    phase = .preparing(String(localized: "正在校验数据文件夹…"))
    dataRootMessage = nil
    let didAccess = selectedURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { selectedURL.stopAccessingSecurityScopedResource() }
    }

    let selection = await Task.detached(priority: .utility) {
      Self.resolveDataRootSelection(selectedURL)
    }.value
    guard !Task.isCancelled else { return }

    let rootURL: URL
    switch selection {
    case .root(let resolvedURL):
      rootURL = resolvedURL
    case .multipleRoots:
      showDataRootSetup(
        message: String(localized: "所选位置包含多个 RepoPress 数据文件夹，请打开其中一个并直接选择它。")
      )
      return
    case .notFound(let probeResult):
      switch probeResult {
      case .new:
        showDataRootSetup(
          message: String(localized: "所选文件夹是空的。如果要使用它，请选择“新建数据文件夹”。")
        )
      case .incompatible(let reason):
        showDataRootSetup(message: friendlyMessage(for: reason))
      case .existing:
        break
      }
      return
    }

    let selectedPaths = WorkbenchRuntimePaths(
      layout: WorkbenchDataRootLayout(rootURL: rootURL)
    )
    let interruptedRestoreRecovery = await Task.detached(priority: .utility) {
      WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
        persistenceFileURL: selectedPaths.persistence.fileURL,
        knowledgeRootURL: selectedPaths.knowledgeLibraryService.rootURL,
        rssDatabaseURL: selectedPaths.rssReaderFileURL,
        attachmentRootURL: selectedPaths.managedAttachmentFileStore.rootDirectoryURL
      )
    }.value
    guard !Task.isCancelled else { return }
    if case .failed(let detail) = interruptedRestoreRecovery {
      showDataRootSetup(
        message: String(
          format: String(localized: "数据文件夹无法校验：%@"),
          detail
        )
      )
      return
    }

    let result = await Task.detached(priority: .utility) {
      WorkbenchDataRootInspector().probe(at: rootURL)
    }.value
    guard case .existing(let manifest) = result else {
      switch result {
      case .new:
        showDataRootSetup(
          message: String(localized: "所选文件夹是空的。如果要使用它，请选择“新建数据文件夹”。")
        )
      case .incompatible(let reason):
        showDataRootSetup(message: friendlyMessage(for: reason))
      case .existing:
        break
      }
      return
    }

    do {
      try bookmarkStore.rememberSelectedRoot(
        rootURL,
        accessURL: selectedURL,
        dataID: manifest.dataID
      )
      try await openStoredRootAndPrepare(using: bookmarkStore)
    } catch {
      showDataRootSetup(message: friendlyMessage(for: error))
    }
  }

  func createNewDataRoot() async {
    guard let parentURL = await WorkbenchDataRootSelectionPanel.chooseDestinationParent(
      forMigration: false
    ) else {
      return
    }
    await createNewDataRoot(in: parentURL)
  }

  /// Testable half of the Powerbox flow. `parentURL` is the directory the
  /// user actually selected, so its security scope must be retained rather
  /// than attempting to mint a separate bookmark for the generated child.
  func createNewDataRoot(in parentURL: URL) async {
    guard let bookmarkStore else { return }

    phase = .preparing(String(localized: "正在新建 RepoPress 数据文件夹…"))
    dataRootMessage = nil
    let didAccess = parentURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { parentURL.stopAccessingSecurityScopedResource() }
    }

    let rootURL = Self.availableDataRootURL(
      in: parentURL,
      reuseEmptyExistingRoot: true
    )
    let appVersion = Self.currentApplicationVersion
    do {
      let manifest = try await Task.detached(priority: .utility) {
        try WorkbenchDataRootManifestStore().initializeNewRoot(
          at: rootURL,
          appVersion: appVersion
        )
      }.value
      try bookmarkStore.rememberSelectedRoot(
        rootURL,
        accessURL: parentURL,
        dataID: manifest.dataID
      )
      try await openStoredRootAndPrepare(using: bookmarkStore)
    } catch {
      if error is WorkbenchDataRootBookmarkError,
         case .existing = WorkbenchDataRootInspector().probe(at: rootURL) {
        showDataRootSetup(
          message: String(
            localized: "数据文件夹已创建，但无法保存持续访问权限。请点击“恢复已有数据文件夹…”并选择刚创建的“RepoPress Data”文件夹。"
          )
        )
        return
      }
      showDataRootSetup(
        message: String(
          format: String(localized: "无法新建数据文件夹：%@"),
          friendlyMessage(for: error)
        )
      )
    }
  }

  func migrateLegacyData() async {
    guard let bookmarkStore,
          Self.legacyDataIsAvailable,
          let parentURL = await WorkbenchDataRootSelectionPanel.chooseDestinationParent(
            forMigration: true
          )
    else {
      return
    }

    phase = .preparing(String(localized: "正在复制并校验旧版数据…"))
    dataRootMessage = nil
    let didAccess = parentURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { parentURL.stopAccessingSecurityScopedResource() }
    }

    let sourceURL = Self.legacyDataRootURL
    let rootURL = Self.availableDataRootURL(
      in: parentURL,
      reuseEmptyExistingRoot: false
    )
    let appVersion = Self.currentApplicationVersion
    do {
      let result = try await Task.detached(priority: .utility) {
        try WorkbenchDataRootMigrator().copyLegacyRoot(
          from: sourceURL,
          to: rootURL,
          appVersion: appVersion
        )
      }.value
      try bookmarkStore.rememberSelectedRoot(
        rootURL,
        accessURL: parentURL,
        dataID: result.manifest.dataID
      )
      try await openStoredRootAndPrepare(using: bookmarkStore)
    } catch {
      showDataRootSetup(
        message: String(
          format: String(localized: "旧版数据迁移失败：%@"),
          friendlyMessage(for: error)
        )
      )
    }
  }

  /// Copies the active managed root into a newly created child directory and
  /// switches the persisted bookmark only after the copy has been verified.
  /// The old root is deliberately retained as a user-controlled fallback.
  func relocateCurrentDataRoot(in parentURL: URL) async -> WorkbenchDataRootMigrationResult? {
    guard let bookmarkStore,
          let sourceSession = dataRootSession,
          let store,
          let rssStore else {
      dataRootMessage = String(localized: "当前数据文件夹尚未准备完成，无法更改位置。")
      return nil
    }
    guard !store.knowledge.isBusy,
          !rssStore.isRefreshing,
          !store.workspaceBackupScheduler.isRunning else {
      dataRootMessage = String(localized: "资料库、RSS 刷新或备份仍在运行，请完成后再更改存储位置。")
      return nil
    }
    guard store.flushPendingChanges() else {
      dataRootMessage = String(localized: "仍有修改未能保存，未更改存储位置。请先解决保存错误。")
      return nil
    }

    phase = .preparing(String(localized: "正在复制并校验当前数据…"))
    dataRootMessage = nil
    rssStore.stopBackgroundRefresh()
    store.workspaceBackupScheduler.stop()
    browserBridge?.stop()

    let didAccess = parentURL.startAccessingSecurityScopedResource()
    defer {
      if didAccess { parentURL.stopAccessingSecurityScopedResource() }
    }
    let destinationRootURL = Self.availableDataRootURL(
      in: parentURL,
      reuseEmptyExistingRoot: false
    )
    let appVersion = Self.currentApplicationVersion
    var installedResult: WorkbenchDataRootMigrationResult?
    do {
      let result = try await Task.detached(priority: .utility) {
        try WorkbenchDataRootMigrator().copyExistingRoot(
          from: sourceSession.layout.rootURL,
          to: destinationRootURL,
          appVersion: appVersion
        )
      }.value
      installedResult = result
      try bookmarkStore.rememberSelectedRoot(
        destinationRootURL,
        accessURL: parentURL,
        dataID: result.manifest.dataID
      )
      dataRootPath = destinationRootURL.path
      return result
    } catch {
      if let installedResult {
        dataRootMessage = String(
          format: String(localized: "数据已安全复制到 %@，但应用未能切换到新位置：%@。当前仍使用原文件夹。"),
          installedResult.destinationRootURL.path,
          friendlyMessage(for: error)
        )
      } else {
        dataRootMessage = String(
          format: String(localized: "更改存储位置失败：%@。原文件夹保持不变。"),
          friendlyMessage(for: error)
        )
      }
      resumeReadyServicesAfterRelocationFailure(store: store, rssStore: rssStore)
      return nil
    }
  }

  func continueNormally() {
    launchRecoveryChoiceRequired = false
    isSafeMode = false
    Task { await start() }
  }

  func continueInSafeMode() {
    launchRecoveryChoiceRequired = false
    isSafeMode = true
    Task { await start() }
  }

  func beginReadyServicesIfNeeded() -> Bool {
    guard !didStartReadyServices else { return false }
    didStartReadyServices = true
    return true
  }

  private func openRememberedDataRoot() async {
    guard let bookmarkStore else { return }
    phase = .preparing(String(localized: "正在检查数据文件夹…"))
    do {
      try await openStoredRootAndPrepare(using: bookmarkStore)
    } catch {
      showDataRootSetup(message: friendlyMessage(for: error))
    }
  }

  private func openStoredRootAndPrepare(
    using bookmarkStore: WorkbenchDataRootBookmarkStore
  ) async throws {
    let session = try await Task.detached(priority: .utility) {
      try bookmarkStore.openStoredRoot()
    }.value
    guard let session else {
      showDataRootSetup(
        message: String(localized: "请恢复以前的数据文件夹，或新建一个工作区。")
      )
      return
    }

    // A process can be terminated after a workspace restore has installed all
    // replacement files but before it removes the transaction marker. In that
    // state the ordinary data-root probe still looks healthy, so recovery must
    // run before accepting either a compatible or incompatible probe result.
    let runtimePaths = WorkbenchRuntimePaths(layout: session.layout)
    let interruptedRestoreRecovery = await Task.detached(priority: .utility) {
      WorkspaceBackupService.recoverInterruptedRestoreIfNeeded(
        persistenceFileURL: runtimePaths.persistence.fileURL,
        knowledgeRootURL: runtimePaths.knowledgeLibraryService.rootURL,
        rssDatabaseURL: runtimePaths.rssReaderFileURL,
        attachmentRootURL: runtimePaths.managedAttachmentFileStore.rootDirectoryURL
      )
    }.value
    guard !Task.isCancelled else {
      didStart = false
      return
    }
    switch interruptedRestoreRecovery {
    case .none:
      break
    case .rolledBack:
      // Re-resolve the bookmark so identity and structure are checked against
      // the fully rolled-back tree while a fresh security-scope lease is held.
      try await openStoredRootAndPrepare(using: bookmarkStore)
      return
    case .failed(let detail):
      dataRootSession = nil
      showDataRootSetup(
        message: String(
          format: String(localized: "数据文件夹无法校验：%@"),
          detail
        )
      )
      return
    }

    switch session.probeResult {
    case .existing:
      dataRootSession = session
      dataRootPath = session.layout.rootURL.path
      canMigrateLegacyData = false
      await prepareRuntime(using: runtimePaths)
    case .new:
      dataRootSession = nil
      showDataRootSetup(
        message: String(localized: "之前的数据文件夹已被移动、删除或清空，请重新选择。")
      )
    case .incompatible(let reason):
      dataRootSession = nil
      showDataRootSetup(message: friendlyMessage(for: reason))
    }
  }

  private func prepareRuntime(using paths: WorkbenchRuntimePaths) async {
    phase = .preparing(String(localized: "正在准备工作台…"))
    let safeMode = isSafeMode
    let preparation = await Task.detached(priority: .utility) {
      let workspaceRestoreOutcome: WorkspaceBackupRestoreStartupOutcome
      let restoreOutcome: KnowledgeLibraryRestoreStartupOutcome
      if safeMode {
        // Safe mode must never install a pending restore. The package remains
        // untouched for the next normal launch.
        workspaceRestoreOutcome = .none
        restoreOutcome = .none
      } else {
        workspaceRestoreOutcome = WorkspaceBackupService.applyPendingRestoreIfNeeded(
          persistenceFileURL: paths.persistence.fileURL,
          knowledgeRootURL: paths.knowledgeLibraryService.rootURL,
          rssDatabaseURL: paths.rssReaderFileURL,
          attachmentRootURL: paths.managedAttachmentFileStore.rootDirectoryURL
        )
        switch workspaceRestoreOutcome {
        case .restored, .failed:
          // A complete package already installed its validated knowledge copy,
          // while a failed package restore must remain the only recovery path
          // attempted during this launch.
          restoreOutcome = .none
        case .none:
          restoreOutcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded(
            rootURL: paths.knowledgeLibraryService.rootURL
          )
        }
      }

      let snapshotSource: WorkbenchInitialSnapshotSource
      do {
        snapshotSource = .preloaded(try paths.persistence.loadWithRecovery())
      } catch {
        snapshotSource = .loadFailure(error.localizedDescription)
      }
      return WorkbenchLaunchPreparation(
        workspaceRestoreOutcome: workspaceRestoreOutcome,
        restoreOutcome: restoreOutcome,
        snapshotSource: snapshotSource
      )
    }.value

    guard !Task.isCancelled else {
      didStart = false
      return
    }
    let rssStore = RSSReaderStore(fileURL: paths.rssReaderFileURL)
    let workbenchStore = WorkbenchStore(
      persistence: paths.persistence,
      initialSnapshotSource: preparation.snapshotSource,
      safeMode: isSafeMode,
      freshWorkspaceSeedPolicy: isSafeMode ? .blank : .softwareGuides,
      knowledgeLibraryService: paths.knowledgeLibraryService,
      managedAttachmentFileStore: paths.managedAttachmentFileStore,
      rssReaderFileURL: paths.rssReaderFileURL,
      workspaceBackupDirectoryURL: paths.workspaceBackupDirectoryURL
    )
    workbenchStore.reportStartupWorkspaceBackupRestoreOutcome(
      preparation.workspaceRestoreOutcome
    )
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if ScreenshotDemoDataService.isEnabledFromEnvironment {
      ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: workbenchStore)
    }
#endif
    workbenchStore.knowledge.reportStartupRestoreOutcome(preparation.restoreOutcome)

    self.store = workbenchStore
    self.rssStore = rssStore
    let browserBridge = KnowledgeBrowserBridge(
      knowledge: workbenchStore.knowledge,
      onOpenDocument: { [weak workbenchStore] _ in
        workbenchStore?.selectSection(.library)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
      }
    )
    self.browserBridge = browserBridge
    dataRootMessage = nil
    phase = .ready
  }

  private func showDataRootSetup(message: String?) {
    dataRootSession = nil
    dataRootMessage = message
    canMigrateLegacyData = Self.legacyDataIsAvailable
    phase = .needsDataRoot
  }

  private func resumeReadyServicesAfterRelocationFailure(
    store: WorkbenchStore,
    rssStore: RSSReaderStore
  ) {
    phase = .ready
    guard !isSafeMode else { return }
    store.workspaceBackupScheduler.start()
    rssStore.startBackgroundRefresh()
    browserBridge?.start()
  }

  nonisolated static func availableDataRootURL(
    in parentURL: URL,
    reuseEmptyExistingRoot: Bool
  ) -> URL {
    let fileManager = FileManager.default
    let inspector = WorkbenchDataRootInspector()
    for index in 1...999 {
      let name = index == 1 ? "RepoPress Data" : "RepoPress Data \(index)"
      let candidate = parentURL.appendingPathComponent(name, isDirectory: true)
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
      if reuseEmptyExistingRoot && inspector.probe(at: candidate) == .new {
        return candidate
      }
    }
    return parentURL.appendingPathComponent(
      "RepoPress Data \(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
  }

  private enum DataRootSelectionResolution: Sendable {
    case root(URL)
    case multipleRoots
    case notFound(WorkbenchDataRootProbeResult)
  }

  private nonisolated static func resolveDataRootSelection(
    _ selectedURL: URL
  ) -> DataRootSelectionResolution {
    let standardizedURL = selectedURL.standardizedFileURL
    let inspector = WorkbenchDataRootInspector()
    let selectedProbe = inspector.probe(at: standardizedURL)
    if case .existing = selectedProbe {
      return .root(standardizedURL)
    }

    let childURLs: [URL]
    do {
      childURLs = try FileManager.default.contentsOfDirectory(
        at: standardizedURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      return .notFound(selectedProbe)
    }

    let existingRoots = childURLs
      .filter { url in
        guard let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
          return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
      }
      .filter { url in
        if case .existing = inspector.probe(at: url) {
          return true
        }
        return false
      }
      .map(\.standardizedFileURL)
      .sorted { $0.path < $1.path }

    switch existingRoots.count {
    case 1:
      return .root(existingRoots[0])
    case 2...:
      return .multipleRoots
    default:
      return .notFound(selectedProbe)
    }
  }

  private func friendlyMessage(for incompatibility: WorkbenchDataRootIncompatibility) -> String {
    switch incompatibility {
    case .rootIsSymbolicLink:
      return String(localized: "不能使用替身或符号链接作为数据文件夹。")
    case .rootIsNotDirectory:
      return String(localized: "所选项不是文件夹。")
    case .rootCannotBeRead(let detail), .malformedManifest(let detail):
      return String(
        format: String(localized: "数据文件夹无法校验：%@"),
        detail
      )
    case .missingManifestForNonEmptyRoot:
      return String(localized: "该文件夹不是 RepoPress 数据文件夹：它包含文件，但缺少数据根标记。")
    case .manifestIsNotRegularFile:
      return String(localized: "RepoPress 数据根标记的类型不正确。")
    case .unsupportedFormatVersion(let found, let supported):
      return String(
        format: String(localized: "数据文件夹版本为 %d，当前应用仅支持 %d。请先升级 RepoPress。"),
        found,
        supported
      )
    case .emptyLastOpenedAppVersion:
      return String(localized: "数据文件夹标记缺少应用版本。")
    case .duplicateComponent:
      return String(localized: "数据文件夹标记包含重复项。")
    case .declaredComponentMissing:
      return String(localized: "数据文件夹缺少已声明的内容。")
    case .declaredComponentHasUnexpectedType, .undeclaredComponentPresent:
      return String(localized: "数据文件夹的内容结构与标记不一致，未对原文件进行修改。")
    }
  }

  private func friendlyMessage(for error: Error) -> String {
    if let error = error as? WorkbenchDataRootBookmarkError {
      switch error {
      case .dataIdentityMismatch:
        return String(localized: "所选路径中的数据已变成另一个工作区。为避免打开错误数据，请手动重新选择。")
      case .invalidStoredRecord, .invalidRelativeRootPath:
        return String(localized: "之前保存的数据文件夹记录已损坏，请重新选择。")
      case .bookmarkCreationFailed(let detail), .bookmarkResolutionFailed(let detail):
        return String(
          format: String(localized: "无法获得数据文件夹的持续访问权限：%@"),
          detail
        )
      case .securityScopedAccessDenied:
        return String(localized: "系统未授予数据文件夹的持续访问权限，请重新选择该文件夹。")
      }
    }
    if let error = error as? WorkbenchDataRootMigrationError {
      switch error {
      case .sourceChangedDuringCopy:
        return String(localized: "复制期间旧数据发生了变化，本次迁移已取消。请关闭其他 RepoPress 窗口后重试。")
      case .sourceContainsNoSupportedComponents:
        return String(localized: "未在本机找到可迁移的旧版工作台、资料库或 RSS 数据。")
      case .destinationAlreadyExists:
        return String(localized: "目标位置已存在同名文件夹，请换一个位置。")
      case .sourceRootIsIncompatible(let incompatibility):
        return friendlyMessage(for: incompatibility)
      default:
        return String(localized: "旧数据未能通过完整性校验，原文件保持不变。")
      }
    }
    if error is WorkbenchDataRootInitializationError {
      return String(localized: "新数据文件夹未能完成初始化，未安装不完整的数据。")
    }
    return error.localizedDescription
  }

  private static var safeModeRequestedByProcess: Bool {
    ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_SAFE_MODE"] == "1"
      || ProcessInfo.processInfo.arguments.contains("--safe-mode")
  }

  private static var currentApplicationVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }

  private static var legacyDataRootURL: URL {
    WorkbenchPersistence().fileURL.deletingLastPathComponent()
  }

  private static var legacyDataIsAvailable: Bool {
    let layout = WorkbenchDataRootLayout(rootURL: legacyDataRootURL)
    guard case .incompatible(.missingManifestForNonEmptyRoot) =
      WorkbenchDataRootInspector().probe(at: layout.rootURL)
    else {
      return false
    }
    return WorkbenchDataRootComponent.allCases.contains { component in
      FileManager.default.fileExists(atPath: layout.componentURL(for: component).path)
    }
  }
}

private struct WorkbenchRuntimePaths: Sendable {
  let persistence: WorkbenchPersistence
  let knowledgeLibraryService: KnowledgeLibraryService
  let rssReaderFileURL: URL
  let managedAttachmentFileStore: ManagedAttachmentFileStore
  let workspaceBackupDirectoryURL: URL

  init(
    persistence: WorkbenchPersistence,
    knowledgeLibraryService: KnowledgeLibraryService,
    rssReaderFileURL: URL,
    managedAttachmentFileStore: ManagedAttachmentFileStore,
    workspaceBackupDirectoryURL: URL
  ) {
    self.persistence = persistence
    self.knowledgeLibraryService = knowledgeLibraryService
    self.rssReaderFileURL = rssReaderFileURL
    self.managedAttachmentFileStore = managedAttachmentFileStore
    self.workspaceBackupDirectoryURL = workspaceBackupDirectoryURL
  }

  init(layout: WorkbenchDataRootLayout) {
    self.init(
      persistence: WorkbenchPersistence(fileURL: layout.workbenchFileURL),
      knowledgeLibraryService: KnowledgeLibraryService(rootURL: layout.knowledgeLibraryURL),
      rssReaderFileURL: layout.rssReaderDatabaseURL,
      managedAttachmentFileStore: ManagedAttachmentFileStore(
        rootDirectoryURL: layout.managedAttachmentsURL
      ),
      workspaceBackupDirectoryURL: layout.rootURL.appendingPathComponent(
        WorkspaceBackupService.automaticBackupDirectoryName,
        isDirectory: true
      )
    )
  }
}

private struct WorkbenchLaunchPreparation: Sendable {
  let workspaceRestoreOutcome: WorkspaceBackupRestoreStartupOutcome
  let restoreOutcome: KnowledgeLibraryRestoreStartupOutcome
  let snapshotSource: WorkbenchInitialSnapshotSource
}

struct WorkbenchLaunchRootView: View {
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  let onReady: (WorkbenchStore, KnowledgeBrowserBridge?) -> Void

  var body: some View {
    Group {
      switch coordinator.phase {
      case .ready:
        if let store = coordinator.store,
           let rssStore = coordinator.rssStore {
          readyContent(
            store: store,
            rssStore: rssStore,
            browserBridge: coordinator.browserBridge
          )
        } else {
          WorkbenchDataRootProgressView(message: String(localized: "正在准备工作台…"))
        }
      case .needsDataRoot:
        WorkbenchDataRootSetupView(coordinator: coordinator)
      case .preparing(let message):
        WorkbenchDataRootProgressView(message: message)
          .task {
            await coordinator.start()
          }
      }
    }
    .alert(
      String(localized: "上次运行未正常结束"),
      isPresented: Binding(
        get: { coordinator.launchRecoveryChoiceRequired },
        set: { isPresented in
          if !isPresented && coordinator.launchRecoveryChoiceRequired {
            coordinator.continueNormally()
          }
        }
      )
    ) {
      Button(String(localized: "安全模式启动")) {
        coordinator.continueInSafeMode()
      }
      Button(String(localized: "正常启动")) {
        coordinator.continueNormally()
      }
    } message: {
      Text(
        String(localized: "应用检测到上次运行可能因崩溃或被强制结束。安全模式会暂停自动预检、预览、后台维护和浏览器连接，便于先恢复草稿并导出诊断信息。")
      )
    }
  }

  @ViewBuilder
  private func readyContent(
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    browserBridge: KnowledgeBrowserBridge?
  ) -> some View {
    if let browserBridge {
      ContentView(store: store, rssStore: rssStore)
        .environmentObject(browserBridge)
        .task {
          guard coordinator.beginReadyServicesIfNeeded() else { return }
          onReady(store, browserBridge)
          if !coordinator.isSafeMode {
            store.workspaceBackupScheduler.start()
            rssStore.startBackgroundRefresh()
            browserBridge.start()
          }
        }
    } else {
      WorkbenchDataRootProgressView(message: String(localized: "正在准备工作台…"))
    }
  }
}
