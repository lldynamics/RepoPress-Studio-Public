import Combine
import CryptoKit
import Foundation
import PublishingKnowledgeCore

public enum WorkspaceBackupSchedulerStatusLevel: Equatable, Sendable {
  case info
  case success
  case warning
  case error
}

public enum WorkspaceBackupCloudUploadStatus: Equatable, Sendable {
  case localCopyComplete
  case waitingForUpload
  case uploadConfirmed
  case uploadFailed(String)
}

/// Owns a background scheduler independently of the main-actor scheduler.
///
/// Explicit invalidation and replacement are serialized by the owning
/// `@MainActor` scheduler. The lease's deinitializer is a final fallback for
/// the case where the owner is released without an explicit stop.
private final class WorkspaceBackupActivityLease {
  // Explicit invalidation/replacement is serialized on the main actor. During
  // deinit the lease has no concurrent owner references, so this final cleanup
  // cannot race an owner operation.
  private var scheduler: NSBackgroundActivityScheduler?

  init(_ scheduler: NSBackgroundActivityScheduler) {
    self.scheduler = scheduler
  }

  func invalidate() {
    scheduler?.invalidate()
    scheduler = nil
  }

  deinit {
    invalidate()
  }
}

@MainActor
public final class WorkspaceBackupScheduler: ObservableObject {
  public static let settingsKey = "workspaceBackupScheduleV1"
  public static let automaticRetentionCount = 12
  public static let automaticRetentionAge: TimeInterval = 90 * 24 * 60 * 60
  public static let automaticRetentionTotalByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024
  public static let selectedDiskBackupMaximumByteCount: Int64 = 20 * 1_024 * 1_024 * 1_024
  public static let selectedDiskRecentInventoryLimit = 12

  @Published public private(set) var settings: WorkspaceBackupScheduleSettings
  @Published public private(set) var recentBackups: [WorkspaceBackupPreview] = []
  @Published public private(set) var invalidRecentBackupCount = 0
  @Published public private(set) var isRunning = false
  @Published public private(set) var statusMessage: String?
  @Published public private(set) var statusLevel: WorkspaceBackupSchedulerStatusLevel?
  @Published public private(set) var cloudUploadStatus: WorkspaceBackupCloudUploadStatus =
    .localCopyComplete

  private weak var store: WorkbenchStore?
  private let defaults: UserDefaults
  private let fileManagerDependency: SendableFileManager
  private var fileManager: FileManager { fileManagerDependency.value }
  private let defaultDestinationFolderURL: URL?
  private var hasStarted = false
  private var backgroundActivity: WorkspaceBackupActivityLease?
  private var inventoryGeneration: UInt64 = 0
  private var inventoryTask: Task<WorkspaceBackupInventoryResult, Never>?
  // Tests can model delayed or failed uploads without contacting iCloud.
  var cloudUploadStatusReader: ((URL) -> WorkspaceBackupCloudUploadStatus)?

  public init(
    store: WorkbenchStore,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    defaultDestinationFolderURL: URL? = nil
  ) {
    self.store = store
    self.defaults = defaults
    self.fileManagerDependency = SendableFileManager(fileManager)
    self.defaultDestinationFolderURL = defaultDestinationFolderURL?.standardizedFileURL
    self.settings = Self.loadSettings(from: defaults)
  }

  public var destinationFolderURL: URL {
    resolvedDestinationFolderURL()
  }

  public var destinationFolderLabel: String {
    destinationFolderURL.path
  }

  public func start() {
    guard !hasStarted else { return }
    hasStarted = true
    scheduleBackgroundActivity()
    // Disabled automation must be inert at launch. The storage-management
    // screen and its explicit refresh action still call refreshRecentBackups.
    guard settings.frequency != .off else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.hasStarted, self.settings.frequency != .off else { return }
      await self.refreshRecentBackups()
      guard self.hasStarted, self.settings.frequency != .off else { return }
      await self.runIfDue()
    }
  }

  public func stop() {
    hasStarted = false
    inventoryGeneration &+= 1
    inventoryTask?.cancel()
    inventoryTask = nil
    backgroundActivity?.invalidate()
    backgroundActivity = nil
  }

  /// Stops future scheduling and waits until the cancelled inventory worker
  /// has left every synchronous FileManager operation. Data-root relocation
  /// uses this stronger boundary before it starts copying the managed root.
  public func stopAndWaitForBackgroundWork() async {
    let pendingInventory = inventoryTask
    stop()
    _ = await pendingInventory?.value
  }

  public func setFrequency(_ frequency: WorkspaceBackupFrequency) {
    guard !isRunning, settings.frequency != frequency else { return }
    settings.frequency = frequency
    persistSettings()
    scheduleBackgroundActivity()
    guard frequency != .off else {
      inventoryGeneration &+= 1
      inventoryTask?.cancel()
      inventoryTask = nil
      return
    }
    Task { @MainActor [weak self] in
      await self?.runIfDue()
    }
  }

  public func setSelectedCategories(_ categories: Set<WorkspaceBackupCategory>) {
    guard !isRunning, !categories.isEmpty else { return }
    settings.selectedCategoryIDs = WorkspaceBackupCategory.allCases
      .filter { categories.contains($0) }.map(\.rawValue)
    _ = persistSettings()
  }

  public var canPreserveAutomaticBackupHistoryOnSelectedDisk: Bool {
    guard let destinationPath = settings.destinationPath,
          !isICloudDestination,
          !isCloudFileProviderDestination else { return false }
    let path = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
    return !path.hasPrefix("/Volumes/") || settings.destinationVolumeUUID != nil
  }

  @discardableResult
  public func setPreserveAutomaticBackupHistoryOnSelectedDisk(_ enabled: Bool) -> Bool {
    guard !isRunning else { return false }
    guard !enabled || canPreserveAutomaticBackupHistoryOnSelectedDisk else { return false }
    guard settings.preserveAutomaticBackupHistoryOnSelectedDisk != enabled else { return true }
    settings.preserveAutomaticBackupHistoryOnSelectedDisk = enabled
    settings.deferAutomaticBackupPruningUntilNextBackup = !enabled
    guard persistSettings() else { return false }
    Task { @MainActor [weak self] in await self?.refreshRecentBackups() }
    return true
  }

  public var selectedCategories: Set<WorkspaceBackupCategory> {
    guard let ids = settings.selectedCategoryIDs else {
      return Set(WorkspaceBackupCategory.allCases)
    }
    return Set(ids.compactMap(WorkspaceBackupCategory.init(rawValue:)))
  }

  public func refreshCloudUploadStatus() {
    guard let path = settings.lastBackupPath else {
      cloudUploadStatus = .localCopyComplete
      return
    }
    cloudUploadStatus = cloudUploadStatus(for: URL(fileURLWithPath: path))
  }

  public func setDestinationFolder(_ url: URL) throws {
    guard !isRunning else { return }
    let folderURL = url.standardizedFileURL
    let destinationIsICloud = Self.isICloudURL(folderURL)
    let destinationIsCloudFileProvider = Self.isCloudFileProviderURL(folderURL)
    let isLocalDestination = !destinationIsICloud && !destinationIsCloudFileProvider
    let selectedVolumeUUID = isLocalDestination
      ? try selectedVolumeUUIDForDestination(folderURL)
      : nil
    var updated = settings
    updated.destinationPath = folderURL.path
    // Selecting a local disk is the explicit opt-in requested for unbounded
    // automatic history. Persist the policy atomically before inventory runs.
    updated.preserveAutomaticBackupHistoryOnSelectedDisk = isLocalDestination
    updated.destinationIsICloud = destinationIsICloud
    updated.destinationVolumeUUID = selectedVolumeUUID
    updated.deferAutomaticBackupPruningUntilNextBackup = !isLocalDestination
    settings = updated
    persistSettings()
    Task { @MainActor [weak self] in
      await self?.refreshRecentBackups()
    }
  }

  public func setICloudDestinationFolder(_ url: URL) {
    guard !isRunning else { return }
    var updated = settings
    updated.destinationPath = url.standardizedFileURL.path
    updated.destinationIsICloud = true
    updated.preserveAutomaticBackupHistoryOnSelectedDisk = false
    updated.destinationVolumeUUID = nil
    updated.deferAutomaticBackupPruningUntilNextBackup = true
    settings = updated
    _ = persistSettings()
    Task { @MainActor [weak self] in await self?.refreshRecentBackups() }
  }

  public func resetDestinationFolder() {
    guard !isRunning else { return }
    settings.destinationPath = nil
    settings.destinationIsICloud = false
    settings.preserveAutomaticBackupHistoryOnSelectedDisk = false
    settings.destinationVolumeUUID = nil
    settings.deferAutomaticBackupPruningUntilNextBackup = true
    persistSettings()
    Task { @MainActor [weak self] in
      await self?.refreshRecentBackups()
    }
  }

  public func runBackupNow() async {
    await performBackup(isAutomatic: false)
  }

  public func refreshRecentBackups() async {
    refreshCloudUploadStatus()
    let folderURL = resolvedDestinationFolderURL()
    inventoryGeneration &+= 1
    let generation = inventoryGeneration
    inventoryTask?.cancel()
    inventoryTask = nil
    if settings.destinationPath != nil && !isICloudDestination {
      do {
        try validateSelectedBackupVolume(folderURL)
      } catch {
        recentBackups = []
        invalidRecentBackupCount = 0
        setStatus(error.localizedDescription, level: .error)
        return
      }
    }
    let appVersion = currentApplicationVersion
    let inventoryFileManager = fileManagerDependency
    let task = Task.detached(priority: .utility) {
      WorkspaceBackupInventoryWorker.refresh(
        folderURL: folderURL,
        applicationVersion: appVersion,
        fileManager: inventoryFileManager.value
      )
    }
    inventoryTask = task
    let result = await task.value
    guard inventoryGeneration == generation, !Task.isCancelled else { return }
    inventoryTask = nil

    switch result {
    case .cancelled:
      return
    case .missingFolder:
      recentBackups = []
      invalidRecentBackupCount = 0
      statusMessage = nil
      statusLevel = nil
    case .success(let previews, let invalidCount):
      recentBackups = previews
      invalidRecentBackupCount = invalidCount
      settings.lastValidationAt = Date()
      guard persistSettings() else { return }
      if invalidCount == 0 {
        setStatus(
          CoreL10n.format("已校验 %d 个自动备份", recentBackups.count),
          level: .success
        )
      } else {
        setStatus(
          CoreL10n.format(
            "已校验 %d 个自动备份；%d 个校验失败",
            recentBackups.count,
            invalidCount
          ),
          level: .warning
        )
      }
    case .failure(let message):
      recentBackups = []
      invalidRecentBackupCount = 0
      setStatus(
        CoreL10n.format(
          "自动备份目录校验失败：%@",
          message
        ),
        level: .error
      )
    }
  }

  private func runIfDue() async {
    guard hasStarted,
      settings.frequency != .off,
      !isRunning,
      shouldRunNow
    else {
      return
    }
    await performBackup(isAutomatic: true)
  }

  private var shouldRunNow: Bool {
    guard let interval = settings.frequency.interval else { return false }
    if let lastBackupPath = settings.lastBackupPath,
      !fileManager.fileExists(atPath: lastBackupPath)
    {
      return true
    }
    guard let lastBackupAt = settings.lastBackupAt else { return true }
    return Date().timeIntervalSince(lastBackupAt) >= interval
  }

  func performBackup(isAutomatic: Bool) async {
    guard !isRunning else { return }
    guard let store else {
      setStatus(
        CoreL10n.text("自动备份暂不可用：工作区尚未准备完成"),
        level: .error
      )
      return
    }

    isRunning = true
    defer { isRunning = false }

    let folderURL = resolvedDestinationFolderURL()
    var transientCandidateURL: URL?
    defer {
      if let transientCandidateURL {
        try? fileManager.removeItem(at: transientCandidateURL)
      }
    }
    do {
      if settings.destinationPath != nil && !isICloudDestination {
        try validateSelectedBackupVolume(folderURL)
      }
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
      let preservesHistory = settings.preserveAutomaticBackupHistoryOnSelectedDisk
        && isLocalDiskDestination
      if preservesHistory {
        let estimate = try estimatedBackupBytes(store: store, categories: selectedCategories)
        try requireSelectedDiskBackupSpace(
          estimatedBytes: estimate,
          at: folderURL
        )
      }
      let finalBackupURL = Self.nextAvailableBackupURL(in: folderURL, fileManager: fileManager) {
        automaticBackupFilename()
      }
      let backupURL = isAutomatic
        ? folderURL.appendingPathComponent(".candidate-\(UUID().uuidString).psworkspacebackup",
          isDirectory: true)
        : finalBackupURL
      // This path is a package created by this operation. If final validation
      // fails (including a changed external-volume identity), clean only this
      // new package and leave all earlier snapshots untouched.
      transientCandidateURL = backupURL
      let schedulerBackupLimits = WorkspaceBackupService.Limits(
        maximumTotalByteCount: !preservesHistory
          ? Self.automaticRetentionTotalByteCount
          : Self.selectedDiskBackupMaximumByteCount
      )
      guard
        let createdPreview = await store.createWorkspaceBackup(
          at: backupURL,
          applicationVersion: currentApplicationVersion,
          limits: schedulerBackupLimits,
          actor: isAutomatic ? .background : .user,
          selectedCategories: selectedCategories
        )
      else {
        throw WorkspaceBackupError.sourceUnavailable(
          CoreL10n.format("%@；备份未创建", store.lastSaveStatus)
        )
      }
      let appVersion = currentApplicationVersion
      let inventoryFileManager = fileManagerDependency
      let verifiedPreview = try await Task.detached(priority: .utility) {
        try WorkspaceBackupService(fileManager: inventoryFileManager.value).inspectBackup(
          at: createdPreview.backupURL,
          currentApplicationVersion: appVersion
        )
      }.value
      if settings.destinationPath != nil && !isICloudDestination {
        try validateSelectedBackupVolume(folderURL)
      }
      let fingerprint = manifestContentFingerprint(at: verifiedPreview.backupURL)
      if isAutomatic, let fingerprint,
        let existingURL = await reusableBackupURL(for: fingerprint, in: folderURL)
      {
        try fileManager.removeItem(at: verifiedPreview.backupURL)
        transientCandidateURL = nil
        cloudUploadStatus = cloudUploadStatus(for: existingURL)
        let removed = try await pruneAfterValidatedBackup(
          in: folderURL, keeping: existingURL, preservesHistory: preservesHistory
        )
        let removedPaths = Set(removed.map { $0.standardizedFileURL.path })
        recentBackups.removeAll { removedPaths.contains($0.backupURL.standardizedFileURL.path) }
        settings.lastBackupAt = Date()
        settings.lastError = nil
        _ = persistSettings()
        setStatus(CoreL10n.text("所选数据没有变化，已跳过本次自动备份"), level: .info)
        return
      }
      if isAutomatic {
        if settings.destinationPath != nil && !isICloudDestination {
          try validateSelectedBackupVolume(folderURL)
        }
        try fileManager.moveItem(at: verifiedPreview.backupURL, to: finalBackupURL)
      }
      transientCandidateURL = nil
      var committedPreview = verifiedPreview
      committedPreview.backupURL = finalBackupURL
      cloudUploadStatus = cloudUploadStatus(for: finalBackupURL)

      if settings.destinationPath != nil && !isICloudDestination {
        try validateSelectedBackupVolume(folderURL)
      }
      let removedURLs = try await pruneAfterValidatedBackup(
        in: folderURL, keeping: finalBackupURL, preservesHistory: preservesHistory
      )
      let removedPaths = Set(removedURLs.map { $0.standardizedFileURL.path })

      var cachedBackups = recentBackups.filter { preview in
        let path = preview.backupURL.standardizedFileURL.path
        return !removedPaths.contains(path) && fileManager.fileExists(atPath: path)
      }
      cachedBackups.removeAll {
        $0.backupURL.standardizedFileURL.path == committedPreview.backupURL.standardizedFileURL.path
      }
      cachedBackups.append(committedPreview)
      recentBackups = cachedBackups.sorted { $0.createdAt > $1.createdAt }

      settings.lastBackupAt = Date()
      settings.lastValidationAt = Date()
      settings.lastBackupPath = committedPreview.backupURL.path
      settings.lastContentFingerprint = fingerprint
      settings.lastError = nil
      settings.deferAutomaticBackupPruningUntilNextBackup = false
      guard persistSettings() else { return }
      setStatus(
        isAutomatic
          ? CoreL10n.format(
            "自动备份完成并校验：%@",
            committedPreview.backupURL.lastPathComponent
          )
          : CoreL10n.format(
            "备份完成并校验：%@",
            committedPreview.backupURL.lastPathComponent
          ),
        level: .success
      )
    } catch {
      settings.lastError = backupErrorDescription(error)
      guard persistSettings() else { return }
      setStatus(
        isAutomatic
          ? CoreL10n.format("自动备份失败：%@", backupErrorDescription(error))
          : CoreL10n.format("备份失败：%@", backupErrorDescription(error)),
        level: .error
      )
    }
  }

  private func reusableBackupURL(for fingerprint: String, in folderURL: URL) async -> URL? {
    guard settings.lastContentFingerprint == fingerprint,
      let path = settings.lastBackupPath
    else { return nil }
    let existingURL = URL(fileURLWithPath: path).standardizedFileURL
    guard existingURL.deletingLastPathComponent().path == folderURL.standardizedFileURL.path,
      fileManager.fileExists(atPath: existingURL.path),
      !isICloudDestination || cloudUploadStatus(for: existingURL) == .uploadConfirmed
    else {
      return nil
    }
    let version = currentApplicationVersion
    let dependency = fileManagerDependency
    let valid = await Task.detached(priority: .utility) {
      do {
        _ = try WorkspaceBackupService(fileManager: dependency.value).inspectBackup(
          at: existingURL, currentApplicationVersion: version
        )
        return true
      } catch {
        // Missing or corrupt older copies must never suppress a new backup.
        return false
      }
    }.value
    guard valid, manifestContentFingerprint(at: existingURL) == fingerprint else { return nil }
    return existingURL
  }

  private func pruneAfterValidatedBackup(
    in folderURL: URL, keeping backupURL: URL, preservesHistory: Bool
  ) async throws -> [URL] {
    // Inventory is read-only. Destructive retention requires a validated
    // replacement, and iCloud additionally requires confirmed upload.
    guard !preservesHistory,
      !isICloudDestination || cloudUploadStatus(for: backupURL) == .uploadConfirmed
    else {
      return []
    }
    if settings.destinationPath != nil && !isICloudDestination {
      try validateSelectedBackupVolume(folderURL)
    }
    let dependency = fileManagerDependency
    return await Task.detached(priority: .utility) {
      WorkspaceBackupInventoryWorker.pruneAutomaticBackups(
        in: folderURL, keeping: backupURL, now: Date(), fileManager: dependency.value
      )
    }.value
  }

  private func requireSelectedDiskBackupSpace(estimatedBytes: Int64, at folderURL: URL) throws {
    let attributes = try fileManager.attributesOfFileSystem(forPath: folderURL.path)
    let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let volumeCapacity = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
    let proportionalReserve = volumeCapacity > 0 ? volumeCapacity / 20 : 0
    let reserve = min(
      max(1 * 1_024 * 1_024 * 1_024, proportionalReserve),
      2 * 1_024 * 1_024 * 1_024
    )
    let required = estimatedBytes.addingReportingOverflow(reserve)
    guard !required.overflow else {
      throw WorkspaceBackupError.insufficientDiskSpace(
        requiredByteCount: Int64.max, availableByteCount: available
      )
    }
    guard available >= required.partialValue else {
      throw WorkspaceBackupError.insufficientDiskSpace(requiredByteCount: required.partialValue, availableByteCount: available)
    }
  }

  private func availableBytes(at folderURL: URL) throws -> Int64 {
    let attributes = try fileManager.attributesOfFileSystem(forPath: folderURL.path)
    return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
  }

  private func validateSelectedBackupVolume(_ folderURL: URL) throws {
    let path = folderURL.standardizedFileURL.path
    guard path == "/Volumes" || path.hasPrefix("/Volumes/") else { return }
    guard path != "/Volumes" else {
      throw WorkspaceBackupError.selectedBackupVolumeUnavailable(path)
    }
    let firstComponent = path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
    let expectedMountPath = "/Volumes/\(firstComponent)"
    let mounted = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
    guard let mountedVolume = mounted.first(where: { volume in
      let mountPath = volume.standardizedFileURL.path
      return mountPath != "/" && mountPath == expectedMountPath
    }) else {
      throw WorkspaceBackupError.selectedBackupVolumeUnavailable(path)
    }
    guard let expectedUUID = settings.destinationVolumeUUID else {
      throw WorkspaceBackupError.selectedBackupVolumeIdentityUnavailable(path)
    }
    guard let actualUUID = Self.volumeUUID(for: mountedVolume), actualUUID == expectedUUID else {
      throw WorkspaceBackupError.selectedBackupVolumeChanged(path)
    }
  }

  private func selectedVolumeUUIDForDestination(_ folderURL: URL) throws -> String? {
    let path = folderURL.standardizedFileURL.path
    guard path != "/Volumes" else {
      throw WorkspaceBackupError.selectedBackupVolumeUnavailable(path)
    }
    guard path.hasPrefix("/Volumes/") else { return Self.volumeUUID(for: folderURL) }
    let component = path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
    let mountPath = "/Volumes/\(component)"
    let mounted = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
    guard let volume = mounted.first(where: { $0.standardizedFileURL.path == mountPath }) else {
      throw WorkspaceBackupError.selectedBackupVolumeUnavailable(path)
    }
    guard let uuid = Self.volumeUUID(for: volume) else {
      throw WorkspaceBackupError.selectedBackupVolumeIdentityUnavailable(path)
    }
    return uuid
  }

  private static func volumeUUID(for url: URL) -> String? {
    try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
  }

  private static func isICloudURL(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let documents = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents", isDirectory: true).standardizedFileURL.path
    if path == documents || path.hasPrefix(documents + "/") { return true }
    return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
  }

  static func isCloudFileProviderURL(_ url: URL, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
    let path = url.standardizedFileURL.path
    let cloudStoragePath = homeURL.appendingPathComponent("Library/CloudStorage", isDirectory: true)
      .standardizedFileURL.path
    return path == cloudStoragePath || path.hasPrefix(cloudStoragePath + "/")
  }

  private var isCloudFileProviderDestination: Bool {
    guard let path = settings.destinationPath else { return false }
    return Self.isCloudFileProviderURL(URL(fileURLWithPath: path))
  }

  private var isLocalDiskDestination: Bool {
    settings.destinationPath != nil && !isICloudDestination && !isCloudFileProviderDestination
  }

  private var isICloudDestination: Bool {
    if settings.destinationIsICloud { return true }
    guard let path = settings.destinationPath else { return false }
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let mobileDocumentsPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents", isDirectory: true).standardizedFileURL.path
    if standardizedPath == mobileDocumentsPath || standardizedPath.hasPrefix(mobileDocumentsPath + "/") {
      return true
    }
    return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
  }

  private func estimatedBackupBytes(
    store: WorkbenchStore,
    categories: Set<WorkspaceBackupCategory>
  ) throws -> Int64 {
    var total: Int64 = 0
    if categories.contains(.workbench) {
      let snapshot = store.persistenceStore.persistence.snapshot(from: store)
      total = Int64(try JSONEncoder().encode(snapshot).count)
      var countedAttachmentPaths = Set<String>()
      let attachments = snapshot.drafts.flatMap(\.attachments)
        + snapshot.recycledDrafts.flatMap { $0.draft.attachments }
        + snapshot.draftVersions.flatMap { $0.draft.attachments }
      for attachment in attachments {
        guard let sourcePath = attachment.sourceFilePath else { continue }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard countedAttachmentPaths.insert(sourceURL.standardizedFileURL.path).inserted else { continue }
        total = try addingEstimate(total, estimatedSize(at: sourceURL))
      }
    }
    if categories.contains(.knowledgeLibrary) {
      let size = try estimatedSize(at: store.knowledge.rootURL)
      total = try addingEstimate(total, size)
    }
    if categories.contains(.rssReader), let rssURL = store.rssReaderFileURL {
      var databaseSize = try estimatedSize(at: rssURL)
      databaseSize = try addingEstimate(
        databaseSize,
        estimatedSize(at: URL(fileURLWithPath: rssURL.path + "-wal"))
      )
      databaseSize = try addingEstimate(
        databaseSize,
        estimatedSize(at: URL(fileURLWithPath: rssURL.path + "-shm"))
      )
      total = try addingEstimate(total, databaseSize)
      total = try addingEstimate(
        total,
        estimatedSize(at: RSSReaderStore.mediaCacheDirectoryURL(for: rssURL))
      )
    }
    if categories.contains(.operationHistory) {
      let history = try WorkbenchOperationLedgerPersistence.encodedDocument(store.operationHistory.document)
      total = try addingEstimate(total, Int64(history.count))
    }
    return total
  }

  private func estimatedSize(at root: URL) throws -> Int64 {
    guard fileManager.fileExists(atPath: root.path) else { return 0 }
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
    if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
    guard values.isDirectory == true,
          let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
          ) else { return 0 }
    var size: Int64 = 0
    for case let fileURL as URL in enumerator {
      let fileValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if fileValues.isRegularFile == true {
        size = try addingEstimate(size, Int64(fileValues.fileSize ?? 0))
      }
    }
    return size
  }

  private func addingEstimate(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let addition = lhs.addingReportingOverflow(rhs)
    guard !addition.overflow else {
      throw WorkspaceBackupError.backupTooLarge(maximumByteCount: Self.selectedDiskBackupMaximumByteCount)
    }
    return addition.partialValue
  }

  private func backupErrorDescription(_ error: Error) -> String {
    let nsError = error as NSError
    let description = error.localizedDescription.lowercased()
    if (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28)
      || description.contains("no space left on device")
      || description.contains("disk full") {
      return CoreL10n.text("目标磁盘空间不足；现有备份已保留，请释放空间或改选容量更大的磁盘后重试。")
    }
    return error.localizedDescription
  }

  private func scheduleBackgroundActivity() {
    backgroundActivity?.invalidate()
    backgroundActivity = nil
    guard hasStarted,
      let interval = settings.frequency.interval
    else {
      return
    }

    let activity = NSBackgroundActivityScheduler(
      identifier: "com.jinfang.PersonalSitePublisherMac.workspace-backup"
    )
    activity.interval = interval
    activity.tolerance = min(interval * 0.2, 6 * 60 * 60)
    activity.qualityOfService = .utility
    activity.repeats = true
    activity.schedule { [weak self] completionHandler in
      Task { @MainActor [weak self] in
        guard let self else {
          completionHandler(.finished)
          return
        }
        await self.runIfDue()
        completionHandler(.finished)
      }
    }
    backgroundActivity = WorkspaceBackupActivityLease(activity)
  }

  func manifestContentFingerprint(at packageURL: URL) -> String? {
    let manifestURL = packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    guard let data = try? Data(contentsOf: manifestURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(WorkspaceBackupManifest.self, from: data) else {
      return nil
    }
    let description = manifest.files.sorted { $0.relativePath < $1.relativePath }
      .map { record in
        let normalized = normalizedFingerprintContent(
          for: record,
          packageURL: packageURL
        )
        return "\(record.relativePath)|\(record.component.rawValue)|\(normalized.byteCount)|\(normalized.sha256)"
      }
      .joined(separator: "\n")
      + "\n" + (manifest.selectedCategories ?? []).map(\.rawValue).sorted().joined(separator: ",")
    return SHA256.hash(data: Data(description.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  private func normalizedFingerprintContent(
    for record: WorkspaceBackupFileRecord,
    packageURL: URL
  ) -> (byteCount: Int64, sha256: String) {
    let fileURL = packageURL.appendingPathComponent(record.relativePath)
    let normalizedData: Data?
    switch record.relativePath {
    case WorkspaceBackupService.operationHistoryRelativePath:
      normalizedData = normalizedOperationHistoryData(at: fileURL)
    case "\(WorkspaceBackupService.knowledgePackageName)/manifest.json":
      normalizedData = normalizedKnowledgeManifestData(at: fileURL)
    default:
      normalizedData = nil
    }
    guard let normalizedData else {
      return (record.byteCount, record.sha256)
    }
    let digest = SHA256.hash(data: normalizedData)
      .map { String(format: "%02x", $0) }.joined()
    return (Int64(normalizedData.count), digest)
  }

  private func normalizedOperationHistoryData(at fileURL: URL) -> Data? {
    guard let data = try? Data(contentsOf: fileURL),
          var document = try? WorkbenchOperationLedgerPersistence.decodedDocument(from: data)
    else { return nil }
    document.records.removeAll {
      $0.kind == .workspaceBackupCreated && $0.actor == .background
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try? encoder.encode(document)
  }

  private func normalizedKnowledgeManifestData(at fileURL: URL) -> Data? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard var manifest = try? decoder.decode(KnowledgeLibraryBackupManifest.self, from: data)
    else { return nil }
    manifest.createdAt = Date(timeIntervalSince1970: 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try? encoder.encode(manifest)
  }

  private func cloudUploadStatus(for packageURL: URL) -> WorkspaceBackupCloudUploadStatus {
    if let cloudUploadStatusReader { return cloudUploadStatusReader(packageURL) }
    guard
      let packageValues = try? packageURL.resourceValues(forKeys: [
        .isUbiquitousItemKey, .ubiquitousItemUploadingErrorKey,
      ]),
      packageValues.isUbiquitousItem == true
    else {
      return isICloudDestination ? .waitingForUpload : .localCopyComplete
    }
    if let error = packageValues.ubiquitousItemUploadingError {
      return .uploadFailed(error.localizedDescription)
    }
    let manifestURL = packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    guard let data = try? Data(contentsOf: manifestURL) else { return .waitingForUpload }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(WorkspaceBackupManifest.self, from: data) else {
      return .waitingForUpload
    }
    let declaredPaths = [WorkspaceBackupService.manifestFileName]
      + manifest.files.map(\.relativePath)
    var uploadErrors: [String] = []
    let uploadStates = declaredPaths.map { relativePath -> Bool? in
      guard !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains("..") else { return nil }
      let fileURL = packageURL.appendingPathComponent(relativePath)
      guard
        let values = try? fileURL.resourceValues(forKeys: [
          .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey,
        ]), values.isUbiquitousItem == true
      else { return nil }
      if let error = values.ubiquitousItemUploadingError {
        uploadErrors.append(error.localizedDescription)
      }
      return values.ubiquitousItemIsUploaded
    }
    return Self.confirmedCloudUploadStatus(
      isUbiquitousPackage: true,
      declaredFileUploadStates: uploadStates,
      uploadErrorDescriptions: uploadErrors
    )
  }

  static func confirmedCloudUploadStatus(
    isUbiquitousPackage: Bool,
    declaredFileUploadStates: [Bool?],
    uploadErrorDescriptions: [String] = []
  ) -> WorkspaceBackupCloudUploadStatus {
    guard isUbiquitousPackage else { return .localCopyComplete }
    if let error = uploadErrorDescriptions.first { return .uploadFailed(error) }
    guard !declaredFileUploadStates.isEmpty,
      declaredFileUploadStates.allSatisfy({ $0 == true })
    else {
      return .waitingForUpload
    }
    return .uploadConfirmed
  }

  private func automaticBackupFilename() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = UUID().uuidString.lowercased()
    let timestamp = formatter.string(from: Date())
    return
      "\(WorkspaceBackupService.automaticBackupFilePrefix)\(timestamp)-\(suffix).psworkspacebackup"
  }

  static func nextAvailableBackupURL(
    in folderURL: URL,
    fileManager: FileManager,
    makeFilename: () -> String
  ) -> URL {
    // A final package path may be used as the manual backup's creation target.
    // Never arm cleanup for a path that existed before this operation.
    while true {
      let candidate = folderURL.appendingPathComponent(makeFilename(), isDirectory: true)
      guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
    }
  }

}

private enum WorkspaceBackupInventoryResult: Sendable {
  case cancelled
  case missingFolder
  case success([WorkspaceBackupPreview], invalidCount: Int)
  case failure(String)
}

/// All directory enumeration, package inspection, recursive sizing, and
/// retention cleanup happen off the scheduler's MainActor. Results are value
/// types and are published only after the caller's generation check.
private enum WorkspaceBackupInventoryWorker {
  private static let automaticRetentionCount = 12
  private static let automaticRetentionAge: TimeInterval = 90 * 24 * 60 * 60
  private static let automaticRetentionTotalByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024
  private static let selectedDiskRecentInventoryLimit = 12

  static func refresh(
    folderURL: URL,
    applicationVersion: String,
    fileManager: FileManager
  ) -> WorkspaceBackupInventoryResult {
    guard !Task.isCancelled else { return .cancelled }
    guard fileManager.fileExists(atPath: folderURL.path) else { return .missingFolder }
    guard !Task.isCancelled else { return .cancelled }
    do {
      let urls = try fileManager.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ).filter { url in
        url.pathExtension.lowercased() == "psworkspacebackup"
          && url.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix)
      }
      let orderedURLs = urls.sorted { lhs, rhs in
        let leftDate =
          (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let rightDate =
          (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        return leftDate > rightDate
      }
      let inventoryURLs = Array(orderedURLs.prefix(selectedDiskRecentInventoryLimit))
      var previews: [WorkspaceBackupPreview] = []
      var invalidCount = 0
      for url in inventoryURLs {
        guard !Task.isCancelled else { return .cancelled }
        do {
          previews.append(
            try WorkspaceBackupService(fileManager: fileManager).inspectBackup(
              at: url,
              currentApplicationVersion: applicationVersion
            ))
        } catch {
          invalidCount += 1
        }
      }
      return .success(previews.sorted { $0.createdAt > $1.createdAt }, invalidCount: invalidCount)
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  static func pruneAutomaticBackups(
    in folderURL: URL,
    keeping currentURL: URL,
    now: Date,
    fileManager: FileManager = .default
  ) -> [URL] {
    guard fileManager.fileExists(atPath: currentURL.path),
      currentURL.deletingLastPathComponent().standardizedFileURL.path
        == folderURL.standardizedFileURL.path,
      let urls = try? fileManager.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    let candidates = urls.filter { url in
      url.pathExtension.lowercased() == "psworkspacebackup"
        && url.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix)
        && url.deletingLastPathComponent().standardizedFileURL.path
          == folderURL.standardizedFileURL.path
    }.sorted { lhs, rhs in
      if lhs.standardizedFileURL.path == currentURL.standardizedFileURL.path {
        return rhs.standardizedFileURL.path != currentURL.standardizedFileURL.path
      }
      if rhs.standardizedFileURL.path == currentURL.standardizedFileURL.path { return false }
      let leftDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let rightDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return leftDate > rightDate
    }

    let cutoff = now.addingTimeInterval(-automaticRetentionAge)
    let currentPath = currentURL.standardizedFileURL.path
    var keptCount = 0
    var keptByteCount: Int64 = 0
    var removedURLs: [URL] = []
    for url in candidates {
      let isCurrent = url.standardizedFileURL.path == currentPath
      let modifiedAt =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      guard !Task.isCancelled else { return removedURLs }
      let byteCount = directoryByteCount(url, fileManager: fileManager)
      let exceedsCount = keptCount >= automaticRetentionCount
      let exceedsAge = modifiedAt < cutoff
      let totalAddition = keptByteCount.addingReportingOverflow(byteCount)
      let exceedsTotal =
        keptByteCount > 0
        && (totalAddition.overflow || totalAddition.partialValue > automaticRetentionTotalByteCount)
      if !isCurrent && (exceedsCount || exceedsAge || exceedsTotal) {
        guard !Task.isCancelled else { return removedURLs }
        // The scheduler owns only its explicit automatic-backup prefix. Keep
        // manual/user-named packages outside this bounded cleanup scope.
        do {
          try fileManager.removeItem(at: url)
          removedURLs.append(url)
        } catch {
          // A failed cleanup is left visible for the next maintenance pass.
        }
        continue
      }
      keptCount += 1
      let addition = keptByteCount.addingReportingOverflow(byteCount)
      keptByteCount = addition.overflow ? Int64.max : addition.partialValue
    }
    return removedURLs
  }

  private static func directoryByteCount(_ url: URL, fileManager: FileManager) -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: []
      )
    else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard !Task.isCancelled else { return total }
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true
      else { continue }
      let size = Int64(values.fileSize ?? 0)
      let addition = total.addingReportingOverflow(size)
      total = addition.overflow ? Int64.max : addition.partialValue
    }
    return total
  }

}

extension WorkspaceBackupScheduler {
  private var currentApplicationVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }

  private func resolvedDestinationFolderURL() -> URL {
    if let destinationPath = settings.destinationPath?.nilIfEmpty {
      let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
      return injectedDestinationReplacingLegacyDefault(destinationURL) ?? destinationURL
    }
    return defaultDestinationFolderURL
      ?? WorkspaceBackupService.defaultAutomaticBackupDirectoryURL(fileManager: fileManager)
  }

  private func injectedDestinationReplacingLegacyDefault(_ candidateURL: URL) -> URL? {
    guard let defaultDestinationFolderURL else { return nil }
    let legacyDefaultURL =
      WorkspaceBackupService
      .defaultAutomaticBackupDirectoryURL(fileManager: fileManager)
      .standardizedFileURL
    guard candidateURL.standardizedFileURL.path == legacyDefaultURL.path else { return nil }
    return defaultDestinationFolderURL
  }

  @discardableResult
  private func persistSettings() -> Bool {
    do {
      let data = try JSONEncoder().encode(settings)
      defaults.set(data, forKey: Self.settingsKey)
      return true
    } catch {
      setStatus(
        CoreL10n.format("自动备份设置保存失败：%@", error.localizedDescription),
        level: .error
      )
      return false
    }
  }

  private func setStatus(
    _ message: String,
    level: WorkspaceBackupSchedulerStatusLevel
  ) {
    statusMessage = message
    statusLevel = level
  }

  private static func loadSettings(from defaults: UserDefaults) -> WorkspaceBackupScheduleSettings {
    guard let data = defaults.data(forKey: settingsKey),
      let settings = try? JSONDecoder().decode(WorkspaceBackupScheduleSettings.self, from: data)
    else {
      return WorkspaceBackupScheduleSettings()
    }
    return settings
  }
}
