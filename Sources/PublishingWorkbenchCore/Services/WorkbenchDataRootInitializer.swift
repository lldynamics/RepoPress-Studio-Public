import Foundation
import OSLog

private let workbenchDataRootLogger = Logger(
  subsystem: "com.jinfang.PersonalSitePublisherMac",
  category: "DataRoot"
)

/// Creates a complete first-run root before App services are constructed.
///
/// Component payloads are prepared in a private staging directory and checked
/// before publication. Each component is renamed into the empty root and the
/// manifest is installed last as the logical commit marker. A thrown error
/// rolls back only entries created by this initialization attempt; pre-existing
/// user data is never removed.
public struct WorkbenchDataRootInitializer: Sendable {
  private let knowledgePersistenceLifecycle: any KnowledgePersistenceLifecycle

  public init() {
    self.init(knowledgePersistenceLifecycle: SQLiteKnowledgePersistenceLifecycle())
  }

  init(knowledgePersistenceLifecycle: any KnowledgePersistenceLifecycle) {
    self.knowledgePersistenceLifecycle = knowledgePersistenceLifecycle
  }

  public func initializeNewRoot(
    at rootURL: URL,
    appVersion: String,
    dataID: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> WorkbenchDataRootManifest {
    do {
      let fileManager = FileManager.default
      let destinationLayout = try prepareDestination(
        at: rootURL,
        fileManager: fileManager
      )
      let stagingLayout = try prepareStagingRoot(
        in: destinationLayout,
        fileManager: fileManager
      )
      defer { try? fileManager.removeItem(at: stagingLayout.rootURL) }

      try bootstrapStagedRoot(
        stagingLayout,
        manifest: WorkbenchDataRootManifest(
          dataID: dataID,
          createdAt: createdAt,
          lastOpenedAppVersion: appVersion,
          components: WorkbenchDataRootComponent.allCases
        ),
        fileManager: fileManager
      )

      let reservedContents = try rootContents(
        destinationLayout.rootURL,
        fileManager: fileManager
      )
      guard reservedContents.isEmpty else {
        throw WorkbenchDataRootInitializationError.rootChangedDuringInitialization
      }
      return try install(
        stagingLayout: stagingLayout,
        destinationLayout: destinationLayout,
        fileManager: fileManager
      )
    } catch {
      logFailure(stage: "initialize-root", error: error)
      throw error
    }
  }

  private func prepareDestination(
    at rootURL: URL,
    fileManager: FileManager
  ) throws -> WorkbenchDataRootLayout {
    let initialProbe = WorkbenchDataRootInspector().probe(at: rootURL)
    guard initialProbe == .new else {
      throw WorkbenchDataRootInitializationError.rootIsNotNew(initialProbe)
    }
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)
    do {
      try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: true)
    } catch {
      logFailure(stage: "prepare-destination", error: error)
      throw WorkbenchDataRootInitializationError.rootPreparationFailed(
        error.localizedDescription
      )
    }
    guard try rootContents(layout.rootURL, fileManager: fileManager).isEmpty else {
      throw WorkbenchDataRootInitializationError.rootChangedDuringInitialization
    }
    return layout
  }

  private func prepareStagingRoot(
    in destinationLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> WorkbenchDataRootLayout {
    let destinationName = destinationLayout.rootURL.lastPathComponent
    let layout = WorkbenchDataRootLayout(
      rootURL: destinationLayout.rootURL.deletingLastPathComponent().appendingPathComponent(
        ".\(destinationName).initialization-\(UUID().uuidString.lowercased()).stage",
        isDirectory: true
      )
    )
    try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: false)
    return layout
  }

  private func bootstrapStagedRoot(
    _ layout: WorkbenchDataRootLayout,
    manifest: WorkbenchDataRootManifest,
    fileManager: FileManager
  ) throws {
    do {
      try bootstrapMissingComponents(in: layout, fileManager: fileManager)
      try WorkbenchDataRootManifestStore().write(manifest, to: layout)
      try validateCompleteRoot(layout)
    } catch {
      logFailure(stage: "bootstrap-staging", error: error)
      throw WorkbenchDataRootInitializationError.componentBootstrapFailed(
        error.localizedDescription
      )
    }
  }

  /// Completes a staging root without replacing components copied from a
  /// legacy source. The inspector can therefore treat every declared
  /// component as required and never silently recreate deleted user data.
  func bootstrapMissingComponents(
    in layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws {
    if !fileManager.fileExists(atPath: layout.workbenchFileURL.path) {
      let profile = SiteProfile.defaultProfile
      let snapshot = WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft.empty(profile: profile)],
        releaseRecords: []
      )
      let workbenchData = try JSONEncoder.workbench.encode(snapshot)
      try workbenchData.write(to: layout.workbenchFileURL, options: [.atomic])
    }

    for directoryName in ["blobs/sha256", "captured/sha256", "normalized/sha256"] {
      try fileManager.createDirectory(
        at: layout.knowledgeLibraryURL.appendingPathComponent(
          directoryName,
          isDirectory: true
        ),
        withIntermediateDirectories: true
      )
    }
    if !fileManager.fileExists(atPath: layout.knowledgeDatabaseURL.path) {
      try createKnowledgeDatabase(at: layout.knowledgeDatabaseURL)
    }
    if !fileManager.fileExists(atPath: layout.rssReaderDatabaseURL.path) {
      try createRSSDatabase(at: layout.rssReaderDatabaseURL, fileManager: fileManager)
    }
    try fileManager.createDirectory(
      at: layout.managedAttachmentsURL,
      withIntermediateDirectories: true
    )
  }

  private func createKnowledgeDatabase(at fileURL: URL) throws {
    _ = try knowledgePersistenceLifecycle.createOrOpenAndValidate(at: fileURL)
  }

  private func createRSSDatabase(
    at fileURL: URL,
    fileManager: FileManager
  ) throws {
    let database = try RSSReaderDatabase(fileURL: fileURL, fileManager: fileManager)
    _ = try database.statistics()
  }

  private func install(
    stagingLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> WorkbenchDataRootManifest {
    var installedURLs: [URL] = []
    do {
      for component in WorkbenchDataRootComponent.allCases {
        let destinationURL = destinationLayout.componentURL(for: component)
        try fileManager.moveItem(
          at: stagingLayout.componentURL(for: component),
          to: destinationURL
        )
        installedURLs.append(destinationURL)
      }
      try fileManager.moveItem(
        at: stagingLayout.manifestURL,
        to: destinationLayout.manifestURL
      )
      installedURLs.append(destinationLayout.manifestURL)
      try validateCompleteRoot(destinationLayout)
      let result = WorkbenchDataRootInspector().probe(at: destinationLayout.rootURL)
      guard case .existing(let installedManifest) = result else {
        throw WorkbenchDataRootInitializationError.verificationFailed(result)
      }
      return installedManifest
    } catch {
      logFailure(stage: "install-components", error: error)
      var cleanupFailures: [String] = []
      for url in installedURLs.reversed() {
        do {
          try fileManager.removeItem(at: url)
        } catch let cleanupError {
          cleanupFailures.append("\(url.path)：\(cleanupError.localizedDescription)")
        }
      }
      let detail = cleanupFailures.isEmpty
        ? error.localizedDescription
        : "\(error.localizedDescription)；安装回滚清理失败：\(cleanupFailures.joined(separator: "；"))"
      throw WorkbenchDataRootInitializationError.componentInstallFailed(
        detail
      )
    }
  }

  func validateCompleteRoot(_ layout: WorkbenchDataRootLayout) throws {
    guard try WorkbenchPersistence(fileURL: layout.workbenchFileURL).load() != nil else {
      throw WorkbenchDataRootInitializationError.componentBootstrapFailed(
        "workbench.json did not contain a snapshot"
      )
    }
    _ = try knowledgePersistenceLifecycle.createOrOpenAndValidate(at: layout.knowledgeDatabaseURL)
    let rssDatabase = try RSSReaderDatabase(fileURL: layout.rssReaderDatabaseURL)
    _ = try rssDatabase.statistics()

    let attachmentValues = try layout.managedAttachmentsURL.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard attachmentValues.isDirectory == true,
          attachmentValues.isSymbolicLink != true else {
      throw WorkbenchDataRootInitializationError.componentBootstrapFailed(
        "ManagedAttachments was not a regular directory"
      )
    }
  }

  private func rootContents(
    _ rootURL: URL,
    fileManager: FileManager
  ) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: []
    )
    .filter { !WorkbenchDataRootFileSystemMetadata.isIgnorableEntry($0) }
    .map(\.standardizedFileURL)
    .sorted { $0.path < $1.path }
  }

  private func logFailure(stage: String, error: Error) {
    let cocoaError = error as NSError
    workbenchDataRootLogger.error(
      "Initialization failed at \(stage, privacy: .public): domain=\(cocoaError.domain, privacy: .public) code=\(cocoaError.code, privacy: .public) detail=\(cocoaError.localizedDescription, privacy: .private)"
    )
  }
}
