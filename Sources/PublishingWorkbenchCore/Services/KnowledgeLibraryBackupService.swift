import CryptoKit
import Darwin
import Foundation

final class KnowledgeLibraryBackupService: @unchecked Sendable {
  struct Limits: Sendable {
    var maximumManifestByteCount: Int
    var maximumFileCount: Int
    var maximumSingleFileByteCount: Int64
    var maximumTotalByteCount: Int64

    init(
      maximumManifestByteCount: Int = 8 * 1_024 * 1_024,
      maximumFileCount: Int = 50_000,
      maximumSingleFileByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024,
      maximumTotalByteCount: Int64 = 20 * 1_024 * 1_024 * 1_024
    ) {
      precondition(maximumManifestByteCount > 0)
      precondition(maximumFileCount > 0)
      precondition(maximumSingleFileByteCount > 0)
      precondition(maximumTotalByteCount > 0)
      self.maximumManifestByteCount = maximumManifestByteCount
      self.maximumFileCount = maximumFileCount
      self.maximumSingleFileByteCount = maximumSingleFileByteCount
      self.maximumTotalByteCount = maximumTotalByteCount
    }
  }

  static let manifestFileName = "manifest.json"
  static let databaseFileName = "library.sqlite"
  private static let storageRootDirectories: Set<String> = [
    "blobs",
    "captured",
    "normalized",
  ]

  private let rootURL: URL
  private let fileManager: FileManager
  private let limits: Limits

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    limits: Limits = Limits()
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
    self.limits = limits
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
    var records = [try validatedFileRecord(
      relativePath: Self.databaseFileName,
      under: temporaryURL
    )]

    for reference in inspection.storageReferences.sorted() {
      try validateStorageReference(reference)
      let copiedURL = temporaryURL.appendingPathComponent(reference)
      try fileManager.createDirectory(
        at: copiedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      records.append(try copyValidatedRegularFile(
        relativePath: reference,
        from: rootURL,
        to: copiedURL
      ))
    }

    records.sort { $0.relativePath < $1.relativePath }
    let totalByteCount = try validateFileLimits(records)
    let manifest = KnowledgeLibraryBackupManifest(
      applicationVersion: applicationVersion,
      databaseUserVersion: inspection.userVersion,
      documentCount: inspection.documentCount,
      folderCount: inspection.folderCount,
      revisionCount: inspection.revisionCount,
      chunkCount: inspection.chunkCount,
      totalByteCount: totalByteCount,
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
      try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
      try encodeManifest(
        validated.manifest,
        to: temporaryURL.appendingPathComponent(Self.manifestFileName)
      )
      for record in validated.manifest.files {
        let destinationURL = temporaryURL.appendingPathComponent(record.relativePath)
        try fileManager.createDirectory(
          at: destinationURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let copiedRecord = try copyValidatedRegularFile(
          relativePath: record.relativePath,
          from: sourceURL,
          to: destinationURL
        )
        guard copiedRecord == record else {
          throw KnowledgeLibraryBackupError.checksumMismatch(record.relativePath)
        }
      }
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
      let destinationURL = stagingURL.appendingPathComponent(record.relativePath)
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let copiedRecord = try copyValidatedRegularFile(
        relativePath: record.relativePath,
        from: pendingURL,
        to: destinationURL
      )
      guard copiedRecord == record else {
        throw KnowledgeLibraryBackupError.checksumMismatch(record.relativePath)
      }
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

    let manifestData: Data
    do {
      manifestData = try BoundedFileReader.data(
        relativePath: Self.manifestFileName,
        under: packageURL,
        maximumByteCount: limits.maximumManifestByteCount
      )
    } catch let error as BoundedFileReadError {
      switch error {
      case .exceedsByteLimit:
        throw KnowledgeLibraryBackupError.manifestTooLarge(
          maximumByteCount: limits.maximumManifestByteCount
        )
      case .cannotOpen(_, let code) where code == ENOENT:
        throw KnowledgeLibraryBackupError.missingFile(Self.manifestFileName)
      default:
        throw KnowledgeLibraryBackupError.invalidPath(Self.manifestFileName)
      }
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
    let declaredTotalByteCount = try validateFileLimits(manifest.files)
    guard manifest.totalByteCount == declaredTotalByteCount else {
      throw KnowledgeLibraryBackupError.invalidManifest("总大小与文件清单不一致")
    }

    var seenPaths = Set<String>()
    for record in manifest.files {
      try validateManifestPath(record.relativePath)
      guard seenPaths.insert(record.relativePath).inserted else {
        throw KnowledgeLibraryBackupError.invalidManifest("文件路径重复：\(record.relativePath)")
      }
      let actualRecord = try validatedFileRecord(
        relativePath: record.relativePath,
        under: packageURL
      )
      guard actualRecord.byteCount == record.byteCount else {
        throw KnowledgeLibraryBackupError.fileSizeMismatch(record.relativePath)
      }
      guard actualRecord.sha256 == record.sha256.lowercased() else {
        throw KnowledgeLibraryBackupError.checksumMismatch(record.relativePath)
      }
    }
    guard seenPaths.contains(Self.databaseFileName) else {
      throw KnowledgeLibraryBackupError.missingFile(Self.databaseFileName)
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
          Self.storageRootDirectories.contains(String(components[0])),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw KnowledgeLibraryBackupError.invalidPath(path)
    }
  }

  private func validateFileLimits(
    _ records: [KnowledgeLibraryBackupFileRecord]
  ) throws -> Int64 {
    guard records.count <= limits.maximumFileCount else {
      throw KnowledgeLibraryBackupError.tooManyFiles(maximumCount: limits.maximumFileCount)
    }

    var totalByteCount: Int64 = 0
    for record in records {
      guard record.byteCount >= 0,
            record.byteCount <= limits.maximumSingleFileByteCount else {
        throw KnowledgeLibraryBackupError.fileTooLarge(
          path: record.relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      let addition = totalByteCount.addingReportingOverflow(record.byteCount)
      guard !addition.overflow,
            addition.partialValue <= limits.maximumTotalByteCount else {
        throw KnowledgeLibraryBackupError.backupTooLarge(
          maximumByteCount: limits.maximumTotalByteCount
        )
      }
      totalByteCount = addition.partialValue
    }
    return totalByteCount
  }

  private func validatedFileRecord(
    relativePath: String,
    under directoryURL: URL
  ) throws -> KnowledgeLibraryBackupFileRecord {
    try withOpenRegularFile(relativePath: relativePath, under: directoryURL) { descriptor, byteCount in
      guard byteCount <= limits.maximumSingleFileByteCount else {
        throw KnowledgeLibraryBackupError.fileTooLarge(
          path: relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      let digest = try sha256(
        descriptor: descriptor,
        relativePath: relativePath,
        expectedByteCount: byteCount
      )
      return KnowledgeLibraryBackupFileRecord(
        relativePath: relativePath,
        byteCount: byteCount,
        sha256: digest
      )
    }
  }

  private func copyValidatedRegularFile(
    relativePath: String,
    from sourceRootURL: URL,
    to destinationURL: URL
  ) throws -> KnowledgeLibraryBackupFileRecord {
    try withOpenRegularFile(relativePath: relativePath, under: sourceRootURL) { descriptor, byteCount in
      guard byteCount <= limits.maximumSingleFileByteCount else {
        throw KnowledgeLibraryBackupError.fileTooLarge(
          path: relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      guard !fileManager.fileExists(atPath: destinationURL.path),
            fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
        throw KnowledgeLibraryBackupError.invalidPath(relativePath)
      }
      let output = try FileHandle(forWritingTo: destinationURL)
      var shouldRemoveDestination = true
      defer {
        try? output.close()
        if shouldRemoveDestination { try? fileManager.removeItem(at: destinationURL) }
      }

      var hasher = SHA256()
      let copiedByteCount = try stream(
        descriptor: descriptor,
        relativePath: relativePath,
        maximumByteCount: limits.maximumSingleFileByteCount
      ) { data in
        hasher.update(data: data)
        try output.write(contentsOf: data)
      }
      guard copiedByteCount == byteCount else {
        throw KnowledgeLibraryBackupError.fileSizeMismatch(relativePath)
      }
      try output.synchronize()
      shouldRemoveDestination = false
      return KnowledgeLibraryBackupFileRecord(
        relativePath: relativePath,
        byteCount: copiedByteCount,
        sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
      )
    }
  }

  private func sha256(
    descriptor: Int32,
    relativePath: String,
    expectedByteCount: Int64
  ) throws -> String {
    var hasher = SHA256()
    let readByteCount = try stream(
      descriptor: descriptor,
      relativePath: relativePath,
      maximumByteCount: limits.maximumSingleFileByteCount
    ) { data in
      hasher.update(data: data)
    }
    guard readByteCount == expectedByteCount else {
      throw KnowledgeLibraryBackupError.fileSizeMismatch(relativePath)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func stream(
    descriptor: Int32,
    relativePath: String,
    maximumByteCount: Int64,
    consume: (Data) throws -> Void
  ) throws -> Int64 {
    var totalByteCount: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if bytesRead == 0 { return totalByteCount }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        throw KnowledgeLibraryBackupError.invalidPath(relativePath)
      }
      let addition = totalByteCount.addingReportingOverflow(Int64(bytesRead))
      guard !addition.overflow, addition.partialValue <= maximumByteCount else {
        throw KnowledgeLibraryBackupError.fileTooLarge(
          path: relativePath,
          maximumByteCount: maximumByteCount
        )
      }
      let data = Data(buffer.prefix(bytesRead))
      try consume(data)
      totalByteCount = addition.partialValue
    }
  }

  private func withOpenRegularFile<Result>(
    relativePath: String,
    under rootURL: URL,
    operation: (Int32, Int64) throws -> Result
  ) throws -> Result {
    let components = relativePath.split(
      separator: "/",
      omittingEmptySubsequences: false
    ).map(String.init)
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.contains("\\"),
          !relativePath.contains("\0"),
          !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw KnowledgeLibraryBackupError.invalidPath(relativePath)
    }

    var directoryDescriptor = rootURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw KnowledgeLibraryBackupError.invalidPath(relativePath)
    }
    defer { Darwin.close(directoryDescriptor) }

    for component in components.dropLast() {
      let nextDescriptor = component.withCString {
        Darwin.openat(
          directoryDescriptor,
          $0,
          O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
      }
      guard nextDescriptor >= 0 else {
        throw fileOpenError(relativePath: relativePath, code: errno)
      }
      Darwin.close(directoryDescriptor)
      directoryDescriptor = nextDescriptor
    }

    let filename = components[components.count - 1]
    let descriptor = filename.withCString {
      Darwin.openat(
        directoryDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
    }
    guard descriptor >= 0 else {
      throw fileOpenError(relativePath: relativePath, code: errno)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size >= 0 else {
      throw KnowledgeLibraryBackupError.invalidPath(relativePath)
    }
    return try operation(descriptor, Int64(metadata.st_size))
  }

  private func fileOpenError(
    relativePath: String,
    code: Int32
  ) -> KnowledgeLibraryBackupError {
    code == ENOENT ? .missingFile(relativePath) : .invalidPath(relativePath)
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
