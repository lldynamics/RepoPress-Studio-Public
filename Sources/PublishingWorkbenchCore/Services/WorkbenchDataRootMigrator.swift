import Foundation

public enum WorkbenchDataRootMigrationError: Error, Equatable, Sendable {
  case sourceDoesNotExist
  case sourceIsSymbolicLink
  case sourceIsNotDirectory
  case sourceAlreadyHasManifest
  case sourceRootIsIncompatible(WorkbenchDataRootIncompatibility)
  case sourceContainsNoSupportedComponents
  case sourceComponentHasUnexpectedType(WorkbenchDataRootComponent)
  case sourceAndDestinationOverlap
  case destinationAlreadyExists
  case destinationParentIsNotDirectory
  case unsupportedFilesystemItem(String)
  case copyVerificationFailed
  case sourceChangedDuringCopy
  case stagedRootIsIncompatible(WorkbenchDataRootIncompatibility)
  case atomicInstallFailed(String)
}

public struct WorkbenchDataRootMigrationResult: Equatable, Sendable {
  public var sourceRootURL: URL
  public var destinationRootURL: URL
  public var manifest: WorkbenchDataRootManifest
  public var copiedRegularFileCount: Int
  public var copiedByteCount: Int64

  public init(
    sourceRootURL: URL,
    destinationRootURL: URL,
    manifest: WorkbenchDataRootManifest,
    copiedRegularFileCount: Int,
    copiedByteCount: Int64
  ) {
    self.sourceRootURL = sourceRootURL.standardizedFileURL
    self.destinationRootURL = destinationRootURL.standardizedFileURL
    self.manifest = manifest
    self.copiedRegularFileCount = copiedRegularFileCount
    self.copiedByteCount = copiedByteCount
  }
}

/// Copies the recognized legacy Application Support data into a new root.
///
/// Installation is intentionally conservative:
/// - the source must be quiescent for the duration of the copy;
/// - symbolic links and special filesystem entries are rejected;
/// - source and staging inventories are compared by relative path, size, and SHA-256;
/// - the source is inventoried again to detect writes during the copy;
/// - the completed staging directory is renamed into place in one operation.
///
/// The destination root must not already exist. The source root is never moved,
/// renamed, or deleted. A second existing root therefore remains an explicit
/// user choice instead of being selected by modification date.
public struct WorkbenchDataRootMigrator: Sendable {
  public init() {}

  /// Copies a complete managed data root to a new location without removing
  /// or modifying the source. The data identity and original creation date
  /// are preserved so a relocated root remains the same workspace.
  public func copyExistingRoot(
    from sourceRootURL: URL,
    to destinationRootURL: URL,
    appVersion: String
  ) throws -> WorkbenchDataRootMigrationResult {
    let fileManager = FileManager.default
    let sourceLayout = WorkbenchDataRootLayout(rootURL: sourceRootURL)
    let destinationLayout = WorkbenchDataRootLayout(rootURL: destinationRootURL)
    let sourceManifest: WorkbenchDataRootManifest
    switch WorkbenchDataRootInspector().probe(at: sourceLayout.rootURL) {
    case .existing(let manifest):
      sourceManifest = manifest
    case .incompatible(let incompatibility):
      throw WorkbenchDataRootMigrationError.sourceRootIsIncompatible(incompatibility)
    case .new:
      throw WorkbenchDataRootMigrationError.sourceDoesNotExist
    }

    try validateDisjointRoots(sourceLayout.rootURL, destinationLayout.rootURL)
    guard !itemExists(at: destinationLayout.rootURL, fileManager: fileManager) else {
      throw WorkbenchDataRootMigrationError.destinationAlreadyExists
    }
    let destinationParentURL = try prepareDestinationParent(
      for: destinationLayout,
      fileManager: fileManager
    )
    let components = sourceManifest.components.sorted { $0.rawValue < $1.rawValue }
    let sourceInventory = try inventory(
      layout: sourceLayout,
      components: components,
      fileManager: fileManager
    )
    let preparation = Preparation(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      destinationParentURL: destinationParentURL,
      components: components,
      sourceInventory: sourceInventory,
      expectedSourceManifest: sourceManifest
    )
    return try installPreparedCopy(
      preparation,
      appVersion: appVersion,
      dataID: sourceManifest.dataID,
      createdAt: sourceManifest.createdAt,
      fileManager: fileManager
    )
  }

  public func copyLegacyRoot(
    from sourceRootURL: URL,
    to destinationRootURL: URL,
    appVersion: String,
    dataID: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> WorkbenchDataRootMigrationResult {
    let fileManager = FileManager.default
    let sourceLayout = WorkbenchDataRootLayout(rootURL: sourceRootURL)
    let destinationLayout = WorkbenchDataRootLayout(rootURL: destinationRootURL)
    let preparation = try prepare(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      fileManager: fileManager
    )
    return try installPreparedCopy(
      preparation,
      appVersion: appVersion,
      dataID: dataID,
      createdAt: createdAt,
      fileManager: fileManager
    )
  }

  struct Preparation {
    var sourceLayout: WorkbenchDataRootLayout
    var destinationLayout: WorkbenchDataRootLayout
    var destinationParentURL: URL
    var components: [WorkbenchDataRootComponent]
    var sourceInventory: [InventoryEntry]
    var expectedSourceManifest: WorkbenchDataRootManifest?
  }

  private func prepare(
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> Preparation {
    try validateSource(sourceLayout, fileManager: fileManager)
    try validateDisjointRoots(sourceLayout.rootURL, destinationLayout.rootURL)
    guard !itemExists(at: destinationLayout.rootURL, fileManager: fileManager) else {
      throw WorkbenchDataRootMigrationError.destinationAlreadyExists
    }
    let destinationParentURL = try prepareDestinationParent(
      for: destinationLayout,
      fileManager: fileManager
    )
    let components = try discoverComponents(in: sourceLayout, fileManager: fileManager)
    guard !components.isEmpty else {
      throw WorkbenchDataRootMigrationError.sourceContainsNoSupportedComponents
    }
    let sourceInventory = try inventory(
      layout: sourceLayout,
      components: components,
      fileManager: fileManager
    )
    return Preparation(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      destinationParentURL: destinationParentURL,
      components: components,
      sourceInventory: sourceInventory,
      expectedSourceManifest: nil
    )
  }

  private func prepareDestinationParent(
    for destinationLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> URL {
    let parentURL = destinationLayout.rootURL.deletingLastPathComponent()
    if itemExists(at: parentURL, fileManager: fileManager) {
      guard isDirectory(at: parentURL) else {
        throw WorkbenchDataRootMigrationError.destinationParentIsNotDirectory
      }
    } else {
      try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }
    return parentURL
  }

  private func installPreparedCopy(
    _ preparation: Preparation,
    appVersion: String,
    dataID: UUID,
    createdAt: Date,
    fileManager: FileManager
  ) throws -> WorkbenchDataRootMigrationResult {
    let stagingLayout = makeStagingLayout(for: preparation)
    try fileManager.createDirectory(at: stagingLayout.rootURL, withIntermediateDirectories: false)
    var stagingWasInstalled = false
    defer {
      if !stagingWasInstalled {
        try? fileManager.removeItem(at: stagingLayout.rootURL)
      }
    }

    try copyComponents(preparation, to: stagingLayout, fileManager: fileManager)
    try verifyCopy(preparation, stagingLayout: stagingLayout, fileManager: fileManager)
    do {
      try rewriteAppOwnedAttachmentPaths(
        in: stagingLayout,
        from: preparation.sourceLayout.rootURL,
        to: preparation.destinationLayout.rootURL,
        fileManager: fileManager
      )
      try WorkbenchDataRootInitializer().bootstrapMissingComponents(
        in: stagingLayout,
        fileManager: fileManager
      )
    } catch {
      throw WorkbenchDataRootMigrationError.copyVerificationFailed
    }
    let manifest = WorkbenchDataRootManifest(
      dataID: dataID,
      createdAt: createdAt,
      lastOpenedAppVersion: appVersion,
      components: WorkbenchDataRootComponent.allCases
    )
    try WorkbenchDataRootManifestStore().write(manifest, to: stagingLayout)
    do {
      try WorkbenchDataRootInitializer().validateCompleteRoot(stagingLayout)
    } catch {
      throw WorkbenchDataRootMigrationError.copyVerificationFailed
    }
    _ = try existingManifest(at: stagingLayout.rootURL)
    let installedManifest = try atomicInstall(
      stagingLayout: stagingLayout,
      destinationLayout: preparation.destinationLayout,
      fileManager: fileManager
    )
    stagingWasInstalled = true
    return migrationResult(for: preparation, manifest: installedManifest)
  }

  private func makeStagingLayout(for preparation: Preparation) -> WorkbenchDataRootLayout {
    let name = preparation.destinationLayout.rootURL.lastPathComponent
    let stagingURL = preparation.destinationParentURL.appendingPathComponent(
      ".\(name).migration-\(UUID().uuidString.lowercased()).stage",
      isDirectory: true
    )
    return WorkbenchDataRootLayout(rootURL: stagingURL)
  }

  private func verifyCopy(
    _ preparation: Preparation,
    stagingLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws {
    let stagingInventory = try inventory(
      layout: stagingLayout,
      components: preparation.components,
      fileManager: fileManager
    )
    guard stagingInventory == preparation.sourceInventory else {
      throw WorkbenchDataRootMigrationError.copyVerificationFailed
    }
    let sourceInventoryAfter = try inventory(
      layout: preparation.sourceLayout,
      components: preparation.components,
      fileManager: fileManager
    )
    guard sourceInventoryAfter == preparation.sourceInventory else {
      throw WorkbenchDataRootMigrationError.sourceChangedDuringCopy
    }
    if let expectedManifest = preparation.expectedSourceManifest {
      guard WorkbenchDataRootInspector().probe(at: preparation.sourceLayout.rootURL)
        == .existing(expectedManifest) else {
        throw WorkbenchDataRootMigrationError.sourceChangedDuringCopy
      }
    }
  }

  private func atomicInstall(
    stagingLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> WorkbenchDataRootManifest {
    guard !itemExists(at: destinationLayout.rootURL, fileManager: fileManager) else {
      throw WorkbenchDataRootMigrationError.destinationAlreadyExists
    }
    do {
      try fileManager.moveItem(at: stagingLayout.rootURL, to: destinationLayout.rootURL)
    } catch {
      throw WorkbenchDataRootMigrationError.atomicInstallFailed(error.localizedDescription)
    }
    return try existingManifest(at: destinationLayout.rootURL)
  }

  private func existingManifest(at rootURL: URL) throws -> WorkbenchDataRootManifest {
    switch WorkbenchDataRootInspector().probe(at: rootURL) {
    case .existing(let manifest):
      return manifest
    case .incompatible(let incompatibility):
      throw WorkbenchDataRootMigrationError.stagedRootIsIncompatible(incompatibility)
    case .new:
      throw WorkbenchDataRootMigrationError.copyVerificationFailed
    }
  }

  private func migrationResult(
    for preparation: Preparation,
    manifest: WorkbenchDataRootManifest
  ) -> WorkbenchDataRootMigrationResult {
    let regularFiles = preparation.sourceInventory.filter { $0.kind == .regularFile }
    return WorkbenchDataRootMigrationResult(
      sourceRootURL: preparation.sourceLayout.rootURL,
      destinationRootURL: preparation.destinationLayout.rootURL,
      manifest: manifest,
      copiedRegularFileCount: regularFiles.count,
      copiedByteCount: regularFiles.reduce(Int64(0)) { $0 + $1.byteCount }
    )
  }

  private func validateSource(
    _ sourceLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws {
    if isSymbolicLink(at: sourceLayout.rootURL, fileManager: fileManager) {
      throw WorkbenchDataRootMigrationError.sourceIsSymbolicLink
    }
    var isDirectoryValue: ObjCBool = false
    guard fileManager.fileExists(
      atPath: sourceLayout.rootURL.path,
      isDirectory: &isDirectoryValue
    ) else {
      throw WorkbenchDataRootMigrationError.sourceDoesNotExist
    }
    guard isDirectoryValue.boolValue else {
      throw WorkbenchDataRootMigrationError.sourceIsNotDirectory
    }
    guard !itemExists(at: sourceLayout.manifestURL, fileManager: fileManager) else {
      throw WorkbenchDataRootMigrationError.sourceAlreadyHasManifest
    }
  }

  private func validateDisjointRoots(_ sourceURL: URL, _ destinationURL: URL) throws {
    let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
    let destinationPath = destinationURL.resolvingSymlinksInPath().standardizedFileURL.path
    if sourcePath == destinationPath
      || destinationPath.hasPrefix(sourcePath + "/")
      || sourcePath.hasPrefix(destinationPath + "/") {
      throw WorkbenchDataRootMigrationError.sourceAndDestinationOverlap
    }
  }

}
