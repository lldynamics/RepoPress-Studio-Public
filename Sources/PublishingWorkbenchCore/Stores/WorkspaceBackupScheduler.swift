import Combine
import Foundation

@MainActor
public final class WorkspaceBackupScheduler: ObservableObject {
  public static let settingsKey = "workspaceBackupScheduleV1"

  @Published public private(set) var settings: WorkspaceBackupScheduleSettings
  @Published public private(set) var recentBackups: [WorkspaceBackupPreview] = []
  @Published public private(set) var invalidRecentBackupCount = 0
  @Published public private(set) var isRunning = false
  @Published public private(set) var statusMessage: String?

  private weak var store: WorkbenchStore?
  private let defaults: UserDefaults
  private let fileManager: FileManager
  private let defaultDestinationFolderURL: URL?
  private let bookmarkCodec: WorkbenchDataRootBookmarkCodec
  private var hasStarted = false
  private var backgroundActivity: NSBackgroundActivityScheduler?

  public init(
    store: WorkbenchStore,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    defaultDestinationFolderURL: URL? = nil,
    bookmarkCodec: WorkbenchDataRootBookmarkCodec = .securityScoped
  ) {
    self.store = store
    self.defaults = defaults
    self.fileManager = fileManager
    self.defaultDestinationFolderURL = defaultDestinationFolderURL?.standardizedFileURL
    self.bookmarkCodec = bookmarkCodec
    self.settings = Self.loadSettings(from: defaults)
  }

  isolated deinit {
    backgroundActivity?.invalidate()
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
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.refreshRecentBackups()
      await self.runIfDue()
    }
  }

  public func stop() {
    hasStarted = false
    backgroundActivity?.invalidate()
    backgroundActivity = nil
  }

  public func setFrequency(_ frequency: WorkspaceBackupFrequency) {
    guard settings.frequency != frequency else { return }
    settings.frequency = frequency
    persistSettings()
    scheduleBackgroundActivity()
    guard frequency != .off else { return }
    Task { @MainActor [weak self] in
      await self?.runIfDue()
    }
  }

  public func setDestinationFolder(_ url: URL) throws {
    let folderURL = url.standardizedFileURL
    var updated = settings
    updated.destinationPath = folderURL.path
    updated.destinationBookmarkData = try bookmarkCodec.create(for: folderURL)
    settings = updated
    persistSettings()
    Task { @MainActor [weak self] in
      await self?.refreshRecentBackups()
    }
  }

  public func resetDestinationFolder() {
    settings.destinationPath = nil
    settings.destinationBookmarkData = nil
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
    let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing { folderURL.stopAccessingSecurityScopedResource() }
    }

    do {
      guard fileManager.fileExists(atPath: folderURL.path) else {
        recentBackups = []
        invalidRecentBackupCount = 0
        return
      }
      let urls = try fileManager.contentsOfDirectory(
        at: folderURL,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ).filter { url in
        url.pathExtension.lowercased() == "psworkspacebackup"
          && url.lastPathComponent.hasPrefix(WorkspaceBackupService.automaticBackupFilePrefix)
      }
      let appVersion = self.currentApplicationVersion
      let scanResult = await Task.detached(priority: .utility) {
        var validPreviews: [WorkspaceBackupPreview] = []
        var invalidCount = 0
        for url in urls {
          do {
            validPreviews.append(
              try WorkspaceBackupService().inspectBackup(
                at: url,
                currentApplicationVersion: appVersion
              )
            )
          } catch {
            invalidCount += 1
          }
        }
        return (validPreviews, invalidCount)
      }.value
      recentBackups = scanResult.0.sorted { $0.createdAt > $1.createdAt }
      invalidRecentBackupCount = scanResult.1
      settings.lastValidationAt = Date()
      persistSettings()
      statusMessage = scanResult.1 == 0
        ? CoreL10n.format("已校验 %d 个自动备份", recentBackups.count)
        : CoreL10n.format(
          "已校验 %d 个自动备份；%d 个校验失败",
          recentBackups.count,
          scanResult.1
        )
    } catch {
      recentBackups = []
      invalidRecentBackupCount = 0
      statusMessage = CoreL10n.format(
        "自动备份目录校验失败：%@",
        error.localizedDescription
      )
    }
  }

  private func runIfDue() async {
    guard settings.frequency != .off,
          !isRunning,
          shouldRunNow else {
      return
    }
    await performBackup(isAutomatic: true)
  }

  private var shouldRunNow: Bool {
    guard let interval = settings.frequency.interval else { return false }
    if let lastBackupPath = settings.lastBackupPath,
       !fileManager.fileExists(atPath: lastBackupPath) {
      return true
    }
    guard let lastBackupAt = settings.lastBackupAt else { return true }
    return Date().timeIntervalSince(lastBackupAt) >= interval
  }

  private func performBackup(isAutomatic: Bool) async {
    guard !isRunning else { return }
    guard let store else {
      statusMessage = CoreL10n.text("自动备份暂不可用：工作区尚未准备完成")
      return
    }

    isRunning = true
    defer { isRunning = false }

    let folderURL = resolvedDestinationFolderURL()
    let didStartAccessing = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing { folderURL.stopAccessingSecurityScopedResource() }
    }

    do {
      try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
      let backupURL = folderURL.appendingPathComponent(automaticBackupFilename())
      guard let createdPreview = await store.createWorkspaceBackup(
        at: backupURL,
        applicationVersion: currentApplicationVersion
      ) else {
        throw WorkspaceBackupError.sourceUnavailable(
          CoreL10n.text("工作台未能保存，自动备份未创建")
        )
      }
      let appVersion = currentApplicationVersion
      let verifiedPreview = try await Task.detached(priority: .utility) {
        try WorkspaceBackupService().inspectBackup(
          at: createdPreview.backupURL,
          currentApplicationVersion: appVersion
        )
      }.value

      settings.lastBackupAt = Date()
      settings.lastValidationAt = Date()
      settings.lastBackupPath = verifiedPreview.backupURL.path
      settings.lastError = nil
      persistSettings()
      await refreshRecentBackups()
      statusMessage = isAutomatic
        ? CoreL10n.format(
          "自动备份完成并校验：%@",
          verifiedPreview.backupURL.lastPathComponent
        )
        : CoreL10n.format(
          "备份完成并校验：%@",
          verifiedPreview.backupURL.lastPathComponent
        )
    } catch {
      settings.lastError = error.localizedDescription
      persistSettings()
      statusMessage = isAutomatic
        ? CoreL10n.format("自动备份失败：%@", error.localizedDescription)
        : CoreL10n.format("备份失败：%@", error.localizedDescription)
    }
  }

  private func scheduleBackgroundActivity() {
    backgroundActivity?.invalidate()
    backgroundActivity = nil
    guard hasStarted,
          let interval = settings.frequency.interval else {
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
    backgroundActivity = activity
  }

  private func automaticBackupFilename() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let timestamp = formatter.string(from: Date())
    return "\(WorkspaceBackupService.automaticBackupFilePrefix)\(timestamp)-\(suffix).psworkspacebackup"
  }

  private var currentApplicationVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }

  private func resolvedDestinationFolderURL() -> URL {
    if let bookmarkData = settings.destinationBookmarkData {
      do {
        let decoded = try bookmarkCodec.resolve(bookmarkData)
        let bookmarkURL = decoded.url.standardizedFileURL
        if let injectedURL = injectedDestinationReplacingLegacyDefault(bookmarkURL) {
          return injectedURL
        }
        if decoded.isStale {
          do {
            settings.destinationBookmarkData = try bookmarkCodec.create(for: bookmarkURL)
            settings.destinationPath = bookmarkURL.path
            persistSettings()
          } catch {
            if let defaultDestinationFolderURL {
              return defaultDestinationFolderURL
            }
          }
        }
        return bookmarkURL
      } catch {
        // A path paired with an invalid bookmark must not redirect a workspace
        // away from its injected data-root backup directory.
        if let defaultDestinationFolderURL {
          return defaultDestinationFolderURL
        }
      }
    }
    if let destinationPath = settings.destinationPath?.nilIfEmpty {
      let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
      return injectedDestinationReplacingLegacyDefault(destinationURL) ?? destinationURL
    }
    return defaultDestinationFolderURL
      ?? WorkspaceBackupService.defaultAutomaticBackupDirectoryURL(fileManager: fileManager)
  }

  private func injectedDestinationReplacingLegacyDefault(_ candidateURL: URL) -> URL? {
    guard let defaultDestinationFolderURL else { return nil }
    let legacyDefaultURL = WorkspaceBackupService
      .defaultAutomaticBackupDirectoryURL(fileManager: fileManager)
      .standardizedFileURL
    guard candidateURL.standardizedFileURL.path == legacyDefaultURL.path else { return nil }
    return defaultDestinationFolderURL
  }

  private func persistSettings() {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: Self.settingsKey)
  }

  private static func loadSettings(from defaults: UserDefaults) -> WorkspaceBackupScheduleSettings {
    guard let data = defaults.data(forKey: settingsKey),
          let settings = try? JSONDecoder().decode(WorkspaceBackupScheduleSettings.self, from: data) else {
      return WorkspaceBackupScheduleSettings()
    }
    return settings
  }
}
