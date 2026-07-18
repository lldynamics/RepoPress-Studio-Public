import CryptoKit
import Foundation

final class KnowledgeLibraryBackupService: @unchecked Sendable {
  static let manifestFileName = "manifest.json"
  static let databaseFileName = "library.sqlite"

  private let rootURL: URL
  private let fileManager: FileManager

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  func createBackup(
    at destinationURL: URL,
    database: KnowledgeDatabase,
    applicationVersion: String
  ) throws -> KnowledgeLibraryBackupPreview {
    let destinationURL = normalizedPackageURL(destinationURL)
    let didAccess = destinationURL.startAccessingSecurityScopedResource()
    defer { if didAccess { destinationURL.stopAccessingSecurityScopedResource() } }

    let parentURL = destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(
      ".\(destinationURL.lastPathComponent).creating-\(UUID().uuidString)",
      isDirectory: true
    )
    try? fileManager.removeItem(at: temporaryURL)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    var shouldRemoveTemporary = true
    defer {
      if shouldRemoveTemporary { try? fileManager.removeItem(at: temporaryURL) }
    }

    let databaseURL = temporaryURL.appendingPathComponent(Self.databaseFileName)
    let inspection = try database.createBackupSnapshot(at: databaseURL)
    var records = [try fileRecord(for: databaseURL, relativePath: Self.databaseFileName)]

    for reference in inspection.storageReferences.sorted() {
      try validateStorageReference(reference)
      let sourceURL = rootURL.appendingPathComponent(reference)
      try validateRegularFile(at: sourceURL, relativePath: reference)
      let copiedURL = temporaryURL.appendingPathComponent(reference)
      try fileManager.createDirectory(
        at: copiedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: sourceURL, to: copiedURL)
      records.append(try fileRecord(for: copiedURL, relativePath: reference))
    }

    records.sort { $0.relativePath < $1.relativePath }
    let manifest = KnowledgeLibraryBackupManifest(
      applicationVersion: applicationVersion,
      databaseUserVersion: inspection.userVersion,
      documentCount: inspection.documentCount,
      folderCount: inspection.folderCount,
      revisionCount: inspection.revisionCount,
      chunkCount: inspection.chunkCount,
      totalByteCount: records.reduce(0) { $0 + $1.byteCount },
      files: records
    )
    try encodeManifest(manifest, to: temporaryURL.appendingPathComponent(Self.manifestFileName))
    _ = try validatedBackup(at: temporaryURL)

    try replaceItem(at: destinationURL, withItemAt: temporaryURL)
    shouldRemoveTemporary = false
    let preview = try inspectBackup(at: destinationURL)
    return preview
  }

  func inspectBackup(at backupURL: URL) throws -> KnowledgeLibraryBackupPreview {
    let packageURL = normalizedPackageURL(backupURL)
    let didAccess = packageURL.startAccessingSecurityScopedResource()
    defer { if didAccess { packageURL.stopAccessingSecurityScopedResource() } }
    return try validatedBackup(at: packageURL).preview
  }

  func stageRestore(from backupURL: URL) throws -> KnowledgeLibraryBackupPreview {
    let sourceURL = normalizedPackageURL(backupURL)
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
    let validated = try validatedBackup(at: sourceURL)

    let pendingURL = Self.pendingRestoreURL(for: rootURL)
    let parentURL = pendingURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let temporaryURL = parentURL.appendingPathComponent(
      ".KnowledgeLibraryPendingRestore-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.copyItem(at: sourceURL, to: temporaryURL)
      _ = try validatedBackup(at: temporaryURL)
      try replaceItem(at: pendingURL, withItemAt: temporaryURL)
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw KnowledgeLibraryBackupError.stagingFailed(error.localizedDescription)
    }
    return validated.preview
  }

  func applyPendingRestoreIfNeeded() throws -> KnowledgeLibraryRestoreStartupResult? {
    let pendingURL = Self.pendingRestoreURL(for: rootURL)
    guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }

    let validated = try validatedBackup(at: pendingURL)
    let parentURL = rootURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let stagingURL = parentURL.appendingPathComponent(
      ".KnowledgeLibraryRestore-\(UUID().uuidString)",
      isDirectory: true
    )
    let applyingURL = parentURL.appendingPathComponent(
      ".KnowledgeLibraryApplying-\(UUID().uuidString).pslibrarybackup",
      isDirectory: true
    )
    var shouldRemoveStaging = true
    defer {
      if shouldRemoveStaging { try? fileManager.removeItem(at: stagingURL) }
    }

    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    for record in validated.manifest.files {
      let sourceURL = pendingURL.appendingPathComponent(record.relativePath)
      let destinationURL = stagingURL.appendingPathComponent(record.relativePath)
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
    _ = try KnowledgeDatabase.inspectBackup(
      at: stagingURL.appendingPathComponent(Self.databaseFileName)
    )

    try fileManager.moveItem(at: pendingURL, to: applyingURL)
    var previousLibraryURL: URL?
    do {
      if fileManager.fileExists(atPath: rootURL.path) {
        let recoveryDirectory = parentURL.appendingPathComponent(
          "KnowledgeLibraryRecovery",
          isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryURL = recoveryDirectory.appendingPathComponent(
          "BeforeRestore-\(formatter.string(from: Date()))-\(UUID().uuidString)",
          isDirectory: true
        )
        try fileManager.moveItem(at: rootURL, to: recoveryURL)
        previousLibraryURL = recoveryURL
      }

      do {
        try fileManager.moveItem(at: stagingURL, to: rootURL)
        shouldRemoveStaging = false
      } catch {
        if let previousLibraryURL,
           !fileManager.fileExists(atPath: rootURL.path) {
          try? fileManager.moveItem(at: previousLibraryURL, to: rootURL)
        }
        throw error
      }
      try? fileManager.removeItem(at: applyingURL)
    } catch {
      if fileManager.fileExists(atPath: applyingURL.path),
         !fileManager.fileExists(atPath: pendingURL.path) {
        try? fileManager.moveItem(at: applyingURL, to: pendingURL)
      }
      throw KnowledgeLibraryBackupError.restoreFailed(error.localizedDescription)
    }

    var restoredPreview = validated.preview
    restoredPreview.backupURL = rootURL
    return KnowledgeLibraryRestoreStartupResult(
      restoredPreview: restoredPreview,
      previousLibraryURL: previousLibraryURL
    )
  }

  static func pendingRestoreURL(for rootURL: URL) -> URL {
    rootURL.deletingLastPathComponent().appendingPathComponent(
      ".KnowledgeLibraryPendingRestore.pslibrarybackup",
      isDirectory: true
    )
  }

  private func validatedBackup(
    at packageURL: URL
  ) throws -> (manifest: KnowledgeLibraryBackupManifest, preview: KnowledgeLibraryBackupPreview) {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw KnowledgeLibraryBackupError.sourceUnavailable(packageURL.path)
    }

    let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
      throw KnowledgeLibraryBackupError.invalidManifest("找不到 \(Self.manifestFileName)")
    }
    let manifest: KnowledgeLibraryBackupManifest
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      manifest = try decoder.decode(KnowledgeLibraryBackupManifest.self, from: manifestData)
    } catch {
      throw KnowledgeLibraryBackupError.invalidManifest(error.localizedDescription)
    }
    guard manifest.formatVersion == KnowledgeLibraryBackupManifest.currentFormatVersion else {
      throw KnowledgeLibraryBackupError.unsupportedFormat(manifest.formatVersion)
    }
    guard manifest.databaseUserVersion <= KnowledgeDatabase.currentSchemaVersion else {
      throw KnowledgeLibraryBackupError.unsupportedDatabaseVersion(
        found: manifest.databaseUserVersion,
        supported: KnowledgeDatabase.currentSchemaVersion
      )
    }

    var seenPaths = Set<String>()
    for record in manifest.files {
      try validateManifestPath(record.relativePath)
      guard seenPaths.insert(record.relativePath).inserted else {
        throw KnowledgeLibraryBackupError.invalidManifest("文件路径重复：\(record.relativePath)")
      }
      let fileURL = packageURL.appendingPathComponent(record.relativePath)
      try validateRegularFile(at: fileURL, relativePath: record.relativePath)
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
      guard Int64(values.fileSize ?? -1) == record.byteCount else {
        throw KnowledgeLibraryBackupError.fileSizeMismatch(record.relativePath)
      }
      guard try sha256(at: fileURL) == record.sha256.lowercased() else {
        throw KnowledgeLibraryBackupError.checksumMismatch(record.relativePath)
      }
    }
    guard seenPaths.contains(Self.databaseFileName) else {
      throw KnowledgeLibraryBackupError.missingFile(Self.databaseFileName)
    }
    guard manifest.totalByteCount == manifest.files.reduce(0, { $0 + $1.byteCount }) else {
      throw KnowledgeLibraryBackupError.invalidManifest("总大小与文件清单不一致")
    }

    let databaseInspection = try KnowledgeDatabase.inspectBackup(
      at: packageURL.appendingPathComponent(Self.databaseFileName)
    )
    let expectedPaths = databaseInspection.storageReferences.union([Self.databaseFileName])
    guard seenPaths == expectedPaths else {
      let missing = expectedPaths.subtracting(seenPaths).sorted()
      let extra = seenPaths.subtracting(expectedPaths).sorted()
      throw KnowledgeLibraryBackupError.metadataMismatch(
        "数据库引用与文件清单不同；缺少 \(missing.joined(separator: ", ").nilIfEmpty ?? "无")，多出 \(extra.joined(separator: ", ").nilIfEmpty ?? "无")"
      )
    }
    guard databaseInspection.userVersion == manifest.databaseUserVersion,
          databaseInspection.documentCount == manifest.documentCount,
          databaseInspection.folderCount == manifest.folderCount,
          databaseInspection.revisionCount == manifest.revisionCount,
          databaseInspection.chunkCount == manifest.chunkCount else {
      throw KnowledgeLibraryBackupError.metadataMismatch("资料数量或数据库版本与清单不一致")
    }

    let preview = KnowledgeLibraryBackupPreview(
      backupURL: packageURL,
      createdAt: manifest.createdAt,
      applicationVersion: manifest.applicationVersion,
      databaseUserVersion: manifest.databaseUserVersion,
      documentCount: manifest.documentCount,
      folderCount: manifest.folderCount,
      revisionCount: manifest.revisionCount,
      chunkCount: manifest.chunkCount,
      totalByteCount: manifest.totalByteCount,
      sampleTitles: databaseInspection.sampleTitles
    )
    return (manifest, preview)
  }

  private func validateManifestPath(_ path: String) throws {
    if path == Self.databaseFileName { return }
    try validateStorageReference(path)
  }

  private func validateStorageReference(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.hasPrefix("/"),
          !path.contains("\\"),
          components.count >= 2,
          (components[0] == "blobs" || components[0] == "normalized"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw KnowledgeLibraryBackupError.invalidPath(path)
    }
  }

  private func validateRegularFile(at fileURL: URL, relativePath: String) throws {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      throw KnowledgeLibraryBackupError.missingFile(relativePath)
    }
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw KnowledgeLibraryBackupError.invalidPath(relativePath)
    }
  }

  private func fileRecord(
    for fileURL: URL,
    relativePath: String
  ) throws -> KnowledgeLibraryBackupFileRecord {
    try validateRegularFile(at: fileURL, relativePath: relativePath)
    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return KnowledgeLibraryBackupFileRecord(
      relativePath: relativePath,
      byteCount: Int64(size),
      sha256: try sha256(at: fileURL)
    )
  }

  private func sha256(at fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func encodeManifest(
    _ manifest: KnowledgeLibraryBackupManifest,
    to fileURL: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: fileURL, options: .atomic)
  }

  private func normalizedPackageURL(_ url: URL) -> URL {
    guard url.pathExtension.lowercased() != "pslibrarybackup" else { return url }
    return url.appendingPathExtension("pslibrarybackup")
  }

  private func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
    guard fileManager.fileExists(atPath: destinationURL.path) else {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      return
    }

    let displacedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
      ".\(destinationURL.lastPathComponent).replaced-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.moveItem(at: destinationURL, to: displacedURL)
    do {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
      try? fileManager.removeItem(at: displacedURL)
    } catch {
      if !fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.moveItem(at: displacedURL, to: destinationURL)
      }
      throw error
    }
  }
}
