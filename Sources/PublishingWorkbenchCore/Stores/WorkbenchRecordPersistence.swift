import CryptoKit
import Darwin
import Foundation

struct WorkbenchRecordManifest: Codable, Equatable {
  static let storageName = "repopress-records"
  let storage: String
  let storageVersion: Int
  let storeID: UUID
  let recovery: Bool
  let directoryName: String

  init(storeID: UUID, directoryName: String, recovery: Bool = false) {
    storage = Self.storageName
    storageVersion = 1
    self.storeID = storeID
    self.directoryName = directoryName
    self.recovery = recovery
  }
}

enum WorkbenchRecordCommitCheckpoint: Sendable {
  case documentsWritten
  case beforeDatabaseCommit
  case databaseCommitted
  case beforeManifestInstall
}

extension WorkbenchPersistence {
  public var recordStoreDirectoryURL: URL {
    fileURL.deletingPathExtension().appendingPathExtension("store")
  }

  /// A portable snapshot used by exports and validation. This deliberately does
  /// not fall back to a recovery point: callers checking a completed save must
  /// prove the current primary state, not an older recoverable version.
  public func loadPrimarySnapshot() throws -> WorkbenchSnapshot {
    try withRecordFileLock { try loadStoredSnapshot(at: fileURL) }
  }

  func loadStoredSnapshot(at url: URL) throws -> WorkbenchSnapshot {
    let data = try BoundedFileReader.data(
      at: url, maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    if let manifest = try recordManifest(from: data) {
      return try loadRecordSnapshot(manifest, parentDirectory: url.deletingLastPathComponent())
    }
    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["formatVersion"] as? Int,
      version > WorkbenchSnapshot.currentFormatVersion
    {
      throw WorkbenchRecordStorageError.unsupportedVersion("工作台版本较新，请使用更新版本的应用打开。")
    }
    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
    try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    return snapshot
  }

  func recordManifest(from data: Data) throws -> WorkbenchRecordManifest? {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["storage"] != nil
    else { return nil }
    guard object["storage"] as? String == WorkbenchRecordManifest.storageName,
      object["storageVersion"] as? Int == 1
    else {
      throw WorkbenchRecordStorageError.unsupportedVersion("不支持的工作台存储格式。")
    }
    let manifest = try JSONDecoder().decode(WorkbenchRecordManifest.self, from: data)
    return manifest
  }

  /// Only the data-root migrator calls this on its private staged copy. Each
  /// slot is rewritten independently so its previous recovery version is kept.
  func replaceStagedRecordSnapshot(
    _ snapshot: WorkbenchSnapshot, manifest: WorkbenchRecordManifest, at markerURL: URL
  ) throws {
    _ = try loadStoredSnapshot(at: markerURL)
    let directory = markerURL.deletingLastPathComponent()
      .appendingPathComponent(manifest.directoryName)
      .appendingPathComponent(manifest.storeID.uuidString)
    let payload = try WorkbenchRecordPayload(snapshot: snapshot)
    try writeDocumentObjects(
      payload.documents,
      under: directory.appendingPathComponent(manifest.recovery ? "RecoveryDocuments" : "Documents")
    )
    let database = try WorkbenchRecordDatabase(
      url: directory.appendingPathComponent(
        manifest.recovery ? "recovery.sqlite" : "records.sqlite"))
    try database.replace(with: payload.records)
    _ = try loadStoredSnapshot(at: markerURL)
  }

  private func loadRecordSnapshot(
    _ manifest: WorkbenchRecordManifest, parentDirectory: URL? = nil
  ) throws -> WorkbenchSnapshot {
    guard manifest.directoryName.hasSuffix(".store"),
      manifest.directoryName != ".store",
      !manifest.directoryName.contains("/"), !manifest.directoryName.contains("\\"),
      !manifest.directoryName.contains("\0")
    else {
      throw WorkbenchRecordStorageError.invalidData("文档存储目录引用无效。")
    }
    let root = (parentDirectory ?? fileURL.deletingLastPathComponent())
      .appendingPathComponent(manifest.directoryName, isDirectory: true)
    try rejectStorageSymlink(root)
    let directory = root.appendingPathComponent(manifest.storeID.uuidString, isDirectory: true)
    try rejectStorageSymlink(directory)
    let databaseURL = directory.appendingPathComponent(
      manifest.recovery ? "recovery.sqlite" : "records.sqlite")
    try rejectStorageSymlink(databaseURL)
    let database = try WorkbenchRecordDatabase(url: databaseURL, readOnly: true)
    let documentsURL = directory.appendingPathComponent(
      manifest.recovery ? "RecoveryDocuments" : "Documents")
    try rejectStorageSymlink(documentsURL)
    return try WorkbenchRecordPayload.snapshot(records: database.records()) { digest in
      let url = documentsURL.appendingPathComponent(digest + ".md")
      try rejectStorageSymlink(url)
      return try BoundedFileReader.data(
        at: url, maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    }
  }

  func commitRecords(
    _ payload: WorkbenchRecordPayload,
    retiredArchives: [WorkbenchRetiredFeatureArchive],
    checkpoint: (WorkbenchRecordCommitCheckpoint) throws -> Void = { _ in }
  ) throws -> WorkbenchPersistenceSaveResult {
    try withRecordFileLock {
      let current = try currentStorageVersion()
      let expected = baseline.version(for: fileURL.path)
      guard expected != nil || current == "missing" else {
        throw WorkbenchRecordStorageError.invalidData("请先载入已有工作台，再保存更改。原始数据未被覆盖。")
      }
      if let expected, expected != current {
        throw WorkbenchRecordStorageError.invalidData("工作台已被另一个写入者更新。已停止保存，请重新载入后合并更改。")
      }
      let result = try commitRecordsUnlocked(
        payload, retiredArchives: retiredArchives, checkpoint: checkpoint)
      baseline.observe(try currentStorageVersion(), for: fileURL.path)
      return result
    }
  }

  private func commitRecordsUnlocked(
    _ payload: WorkbenchRecordPayload,
    retiredArchives: [WorkbenchRetiredFeatureArchive],
    checkpoint: (WorkbenchRecordCommitCheckpoint) throws -> Void
  ) throws -> WorkbenchPersistenceSaveResult {
    try rejectStorageSymlink(fileURL)
    try rejectStorageSymlink(lastKnownGoodURL)
    try persistRetiredFeatureArchives(retiredArchives)

    let existingData = try? BoundedFileReader.data(
      at: fileURL, maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    let existingManifest = existingData.flatMap { try? recordManifest(from: $0) }
    let previous: WorkbenchSnapshot?
    do {
      previous = try loadWithRecoveryUnlocked().snapshot
    } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
      throw WorkbenchRecordStorageError.unsupportedVersion(message)
    } catch { previous = nil }
    // A damaged store is preserved as evidence. Recovery writes a fresh
    // generation instead of overwriting the sole valid recovery database.
    let reusableManifest: WorkbenchRecordManifest?
    if let existingManifest, !existingManifest.recovery,
      (try? loadRecordSnapshot(existingManifest)) != nil
    {
      reusableManifest =
        existingManifest.directoryName == recordStoreDirectoryURL.lastPathComponent
        ? existingManifest : nil
    } else {
      reusableManifest = nil
    }
    let manifest =
      reusableManifest
      ?? WorkbenchRecordManifest(
        storeID: UUID(), directoryName: recordStoreDirectoryURL.lastPathComponent)
    let directory = try checkedRecordDirectory(for: manifest.storeID, create: true)
    try writeDocumentObjects(
      payload.documents, under: directory.appendingPathComponent("Documents"))
    try checkpoint(.documentsWritten)

    let databaseURL = directory.appendingPathComponent("records.sqlite")
    try rejectStorageSymlink(databaseURL)
    let database = try WorkbenchRecordDatabase(url: databaseURL, create: true)
    var backupWarning: String?
    do {
      if reusableManifest != nil {
        // Copy exactly the objects referenced by the raw database rows. A
        // decoded snapshot may normalize retention, and must not be paired
        // with a backup of the unnormalized database.
        let digests = try WorkbenchRecordPayload.documentDigests(in: database.records())
        var objects: [String: Data] = [:]
        for digest in digests {
          let url = directory.appendingPathComponent("Documents").appendingPathComponent(
            digest + ".md")
          try rejectStorageSymlink(url)
          objects[digest] = try BoundedFileReader.data(
            at: url, maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
        }
        try writeDocumentObjects(
          objects, under: directory.appendingPathComponent("RecoveryDocuments"))
        try installDatabaseBackup(database, in: directory)
      } else if let previous {
        let backupPayload = try WorkbenchRecordPayload(snapshot: previous)
        try writeDocumentObjects(
          backupPayload.documents, under: directory.appendingPathComponent("RecoveryDocuments"))
        let recoveryDB = try WorkbenchRecordDatabase(
          url: directory.appendingPathComponent("recovery.sqlite"), create: true)
        try recoveryDB.replace(with: backupPayload.records)
      }
    } catch {
      // Saving current work remains possible, but the recovery guarantee is
      // reported accurately. Never replace a valid backup with corrupt bytes.
      backupWarning = error.localizedDescription
    }

    try checkpoint(.beforeDatabaseCommit)
    try database.replace(with: payload.records)
    try checkpoint(.databaseCommitted)
    // Validate records and every referenced Markdown object before publishing
    // a new manifest. Existing commits are protected by the SQLite transaction.
    _ = try loadRecordSnapshot(manifest)

    if previous == nil && backupWarning == nil {
      do {
        try writeDocumentObjects(
          payload.documents, under: directory.appendingPathComponent("RecoveryDocuments"))
        try installDatabaseBackup(database, in: directory)
      } catch { backupWarning = error.localizedDescription }
    }
    try checkpoint(.beforeManifestInstall)
    if reusableManifest == nil {
      try preserveLegacyPersistenceFiles(in: directory)
      // Persist every directory entry before a marker can make this new
      // generation authoritative, including the legacy-recovery DB branch.
      try syncStorageFile(databaseURL)
      if backupWarning == nil {
        try syncStorageFile(directory.appendingPathComponent("recovery.sqlite"))
      }
      try syncStorageFile(directory)
      try syncStorageFile(recordStoreDirectoryURL)
      try syncStorageFile(fileURL.deletingLastPathComponent())
      if backupWarning == nil {
        do {
          try writeStorageData(
            JSONEncoder().encode(
              WorkbenchRecordManifest(
                storeID: manifest.storeID, directoryName: manifest.directoryName, recovery: true)),
            to: lastKnownGoodURL)
        } catch { backupWarning = error.localizedDescription }
      }
      try writeStorageData(JSONEncoder().encode(manifest), to: fileURL)
    } else if backupWarning == nil {
      // Also repairs a missing/damaged recovery manifest after a successful
      // checkpoint without treating the marker itself as user data.
      do {
        try writeStorageData(
          JSONEncoder().encode(
            WorkbenchRecordManifest(
              storeID: manifest.storeID, directoryName: manifest.directoryName, recovery: true)),
          to: lastKnownGoodURL)
      } catch { backupWarning = error.localizedDescription }
    }
    if backupWarning == nil { pruneUnreferencedDocumentObjects(in: directory) }
    return backupWarning.map { .savedWithoutBackup($0) } ?? .saved
  }

  /// Runs only while holding the writer lock, after both durable database
  /// slots and their manifests are installed. Only app-owned digest filenames
  /// are eligible; migration and forensic archives retain their own lifecycle.
  private func pruneUnreferencedDocumentObjects(in directory: URL) {
    for (databaseName, folder) in [
      ("records.sqlite", "Documents"), ("recovery.sqlite", "RecoveryDocuments"),
    ] {
      do {
        let database = try WorkbenchRecordDatabase(
          url: directory.appendingPathComponent(databaseName), readOnly: true)
        let retained = try WorkbenchRecordPayload.documentDigests(in: database.records())
        let documents = directory.appendingPathComponent(folder)
        try rejectStorageSymlink(documents)
        for url in try FileManager.default.contentsOfDirectory(
          at: documents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        {
          let digest = url.deletingPathExtension().lastPathComponent
          guard url.pathExtension == "md", WorkbenchRecordPayload.isValidDigest(digest),
            !retained.contains(digest)
          else { continue }
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
          try FileManager.default.removeItem(at: url)
        }
      } catch {
        // A failed cleanup leaves extra recoverable objects, never missing
        // content. The next successful checkpoint retries this bounded pass.
        continue
      }
    }
  }

  private func checkedRecordDirectory(for id: UUID, create: Bool = false) throws -> URL {
    let root = recordStoreDirectoryURL
    try rejectStorageSymlink(root)
    let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
    try rejectStorageSymlink(directory)
    if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return directory
  }

  private func writeDocumentObjects(_ objects: [String: Data], under directory: URL) throws {
    try rejectStorageSymlink(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (digest, data) in objects {
      guard WorkbenchRecordPayload.isValidDigest(digest),
        WorkbenchRecordPayload.digest(data) == digest
      else {
        throw WorkbenchRecordStorageError.invalidData("文章正文摘要无效。")
      }
      let url = directory.appendingPathComponent(digest + ".md")
      try rejectStorageSymlink(url)
      if FileManager.default.fileExists(atPath: url.path) {
        // Empty Markdown is valid. The bounded reader requires a positive
        // ceiling; exact byte equality still rejects a nonempty replacement.
        guard try BoundedFileReader.data(at: url, maximumByteCount: max(1, data.count)) == data
        else {
          throw WorkbenchRecordStorageError.invalidData("已保存的文章正文损坏，原文件已保留。")
        }
      } else {
        try writeStorageData(data, to: url)
      }
    }
  }

  private func installDatabaseBackup(_ database: WorkbenchRecordDatabase, in directory: URL) throws
  {
    let temporary = directory.appendingPathComponent(".recovery-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try database.backup(to: temporary)
    let verificationDatabase = try WorkbenchRecordDatabase(url: temporary, readOnly: true)
    _ = try WorkbenchRecordPayload.snapshot(records: verificationDatabase.records()) { digest in
      let url = directory.appendingPathComponent("RecoveryDocuments").appendingPathComponent(
        digest + ".md")
      try rejectStorageSymlink(url)
      return try BoundedFileReader.data(
        at: url, maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    }
    try syncStorageFile(temporary)
    let destination = directory.appendingPathComponent("recovery.sqlite")
    try rejectStorageSymlink(destination)
    guard Darwin.rename(temporary.path, destination.path) == 0 else { throw storagePOSIXError() }
    try syncStorageFile(directory)
  }

  private func preserveLegacyPersistenceFiles(in directory: URL) throws {
    let archive = directory.appendingPathComponent("MigrationSource", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    for source in [fileURL, lastKnownGoodURL]
    where FileManager.default.fileExists(atPath: source.path) {
      let destination = archive.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.copyItem(at: source, to: destination)
      let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
      if attributes[.type] as? FileAttributeType == .typeRegular {
        try syncStorageFile(destination)
        guard try streamingStorageDigest(source) == streamingStorageDigest(destination) else {
          throw WorkbenchRecordStorageError.invalidData("旧工作台迁移备份校验失败。")
        }
      }
    }
    try syncStorageFile(archive)
  }

  private func streamingStorageDigest(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      digest.update(data: chunk)
    }
    return Data(digest.finalize())
  }

  private func rejectStorageSymlink(_ url: URL) throws {
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw WorkbenchRecordStorageError.invalidData("工作台存储文件不能是符号链接：\(url.lastPathComponent)")
    }
  }

  func writeStorageData(_ data: Data, to url: URL) throws {
    try rejectStorageSymlink(url)
    try data.write(to: url, options: .atomic)
    try syncStorageFile(url)
    try syncStorageFile(url.deletingLastPathComponent())
  }

  private func syncStorageFile(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw storagePOSIXError() }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw storagePOSIXError() }
  }

  private func storagePOSIXError() -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  func withRecordFileLock<T>(_ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockURL = fileURL.deletingPathExtension().appendingPathExtension("store.lock")
    let descriptor = Darwin.open(
      lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw storagePOSIXError() }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw storagePOSIXError() }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }

  func currentStorageVersion() throws -> String {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return "missing" }
    try rejectStorageSymlink(fileURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    if let size = attributes[.size] as? NSNumber,
      size.int64Value > Int64(WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    {
      // A corrupt oversized primary must not prevent loading its valid
      // recovery copy. Stream only the revision fingerprint, not the payload.
      return "oversized:"
        + (try streamingStorageDigest(fileURL)).map { String(format: "%02x", $0) }.joined()
    }
    let data = try BoundedFileReader.data(
      at: fileURL,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount)
    let digest = WorkbenchRecordPayload.digest(data)
    let manifest: WorkbenchRecordManifest?
    do {
      manifest = try recordManifest(from: data)
    } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
      throw WorkbenchRecordStorageError.unsupportedVersion(message)
    } catch { manifest = nil }
    guard let manifest else {
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = object["formatVersion"] as? Int,
        version > WorkbenchSnapshot.currentFormatVersion
      {
        throw WorkbenchRecordStorageError.unsupportedVersion("工作台版本较新，请使用更新版本的应用打开。")
      }
      return "legacy:" + digest
    }
    let directory = fileURL.deletingLastPathComponent().appendingPathComponent(
      manifest.directoryName
    )
    .appendingPathComponent(manifest.storeID.uuidString)
    let databaseURL = directory.appendingPathComponent(
      manifest.recovery ? "recovery.sqlite" : "records.sqlite")
    // Resolve/validate the manifest before opening its database so path or
    // symlink injection cannot turn a version check into an arbitrary read.
    guard manifest.directoryName == recordStoreDirectoryURL.lastPathComponent else {
      return "foreign:" + digest
    }
    try rejectStorageSymlink(recordStoreDirectoryURL)
    try rejectStorageSymlink(directory)
    try rejectStorageSymlink(databaseURL)
    do {
      let database = try WorkbenchRecordDatabase(url: databaseURL, readOnly: true)
      return "records:\(digest):\(try database.revision)"
    } catch WorkbenchRecordStorageError.unsupportedVersion(let message) {
      throw WorkbenchRecordStorageError.unsupportedVersion(message)
    } catch { return "unreadable:" + digest }
  }
}
