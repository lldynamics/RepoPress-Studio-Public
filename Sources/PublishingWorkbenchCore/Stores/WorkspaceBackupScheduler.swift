import Combine
import Foundation

public enum WorkspaceBackupSchedulerStatusLevel: Equatable, Sendable {
  case info
  case success
  case warning
  case error
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

  @Published public private(set) var settings: WorkspaceBackupScheduleSettings
  @Published public private(set) var recentBackups: [WorkspaceBackupPreview] = []
  @Published public private(set) var invalidRecentBackupCount = 0
  @Published public private(set) var isRunning = false
  @Published public private(set) var statusMessage: String?
  @Published public private(set) var statusLevel: WorkspaceBackupSchedulerStatusLevel?

  private weak var store: WorkbenchStore?
  private let defaults: UserDefaults
  private let fileManagerDependency: SendableFileManager
  private var fileManager: FileManager { fileManagerDependency.value }
  private let defaultDestinationFolderURL: URL?
  private var hasStarted = false
  private var backgroundActivity: WorkspaceBackupActivityLease?
  private var inventoryGeneration: UInt64 = 0
  private var inventoryTask: Task<WorkspaceBackupInventoryResult, Never>?

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
    guard settings.frequency != frequency else { return }
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

  public func setDestinationFolder(_ url: URL) throws {
    let folderURL = url.standardizedFileURL
    var updated = settings
    updated.destinationPath = folderURL.path
    settings = updated
    persistSettings()
    Task { @MainActor [weak self] in
      await self?.refreshRecentBackups()
    }
  }

  public func resetDestinationFolder() {
    settings.destinationPath = nil
    persistSettings()
    Task { @MainActor [weak self] in
      await self?.refreshRecentBackups()
    }
  }

  public func runBackupNow() async {
    await performBackup(isAutomatic: false)
  }

  public func refreshRecentBackups() async {
    let folderURL = resolvedDestinationFolderURL()
    inventoryGeneration &+= 1
    let generation = inventoryGeneration
    inventoryTask?.cancel()
    let appVersion = currentApplicationVersion
    let inventoryFileManager = fileManagerDependency
    let task = Task.detached(priority: .utility) {
      WorkspaceBackupInventoryWorker.refresh(
        folderURL: folderURL,
        applicationVersion: appVersion,
        now: Date(),
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

  private func performBackup(isAutomatic: Bool) async {
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
    do {
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
      let backupURL = folderURL.appendingPathComponent(automaticBackupFilename())
      let schedulerBackupLimits = WorkspaceBackupService.Limits(
        maximumTotalByteCount: Self.automaticRetentionTotalByteCount
      )
      guard
        let createdPreview = await store.createWorkspaceBackup(
          at: backupURL,
          applicationVersion: currentApplicationVersion,
          limits: schedulerBackupLimits
        )
      else {
        throw WorkspaceBackupError.sourceUnavailable(
          CoreL10n.text("工作台未能保存，自动备份未创建")
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

      let removedURLs = await Task.detached(priority: .utility) {
        WorkspaceBackupInventoryWorker.pruneAutomaticBackups(
          in: folderURL,
          keeping: verifiedPreview.backupURL,
          now: Date(),
          fileManager: inventoryFileManager.value
        )
      }.value

      let removedPaths = Set(removedURLs.map { $0.standardizedFileURL.path })
      var cachedBackups = recentBackups.filter { preview in
        let path = preview.backupURL.standardizedFileURL.path
        return !removedPaths.contains(path)
          && fileManager.fileExists(atPath: path)
      }
      cachedBackups.removeAll {
        $0.backupURL.standardizedFileURL.path == verifiedPreview.backupURL.standardizedFileURL.path
      }
      cachedBackups.append(verifiedPreview)
      recentBackups = cachedBackups.sorted { $0.createdAt > $1.createdAt }

      settings.lastBackupAt = Date()
      settings.lastValidationAt = Date()
      settings.lastBackupPath = verifiedPreview.backupURL.path
      settings.lastError = nil
      guard persistSettings() else { return }
      setStatus(
        isAutomatic
          ? CoreL10n.format(
            "自动备份完成并校验：%@",
            verifiedPreview.backupURL.lastPathComponent
          )
          : CoreL10n.format(
            "备份完成并校验：%@",
            verifiedPreview.backupURL.lastPathComponent
          ),
        level: .success
      )
    } catch {
      settings.lastError = error.localizedDescription
      guard persistSettings() else { return }
      setStatus(
        isAutomatic
          ? CoreL10n.format("自动备份失败：%@", error.localizedDescription)
          : CoreL10n.format("备份失败：%@", error.localizedDescription),
        level: .error
      )
    }
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

  private func automaticBackupFilename() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let timestamp = formatter.string(from: Date())
    return
      "\(WorkspaceBackupService.automaticBackupFilePrefix)\(timestamp)-\(suffix).psworkspacebackup"
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

  static func refresh(
    folderURL: URL,
    applicationVersion: String,
    now: Date,
    fileManager: FileManager
  ) -> WorkspaceBackupInventoryResult {
    guard !Task.isCancelled else { return .cancelled }
    guard fileManager.fileExists(atPath: folderURL.path) else { return .missingFolder }
    _ = pruneAutomaticBackups(in: folderURL, keeping: nil, now: now, fileManager: fileManager)
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
      var previews: [WorkspaceBackupPreview] = []
      var invalidCount = 0
      for url in urls {
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
    keeping currentURL: URL?,
    now: Date,
    fileManager: FileManager = .default
  ) -> [URL] {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    let candidates = urls.filter { url in
      url.pathExtension.lowercased() == "psworkspacebackup"
        && url.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix)
        && url.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL
    }.sorted { lhs, rhs in
      let leftDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let rightDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return leftDate > rightDate
    }

    let cutoff = now.addingTimeInterval(-automaticRetentionAge)
    let currentPath = currentURL?.standardizedFileURL.path
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
