import CryptoKit
import Foundation

extension WorkbenchDataRootMigrator {
  enum InventoryKind: String, Equatable, Sendable {
    case directory
    case regularFile
  }

  struct InventoryEntry: Equatable, Sendable {
    var relativePath: String
    var kind: InventoryKind
    var byteCount: Int64
    var sha256: String?
  }

  struct MigrationPayloadItem: Equatable, Sendable {
    var url: URL
    var expectedKind: InventoryKind
  }

  func inventory(
    layout: WorkbenchDataRootLayout,
    components: [WorkbenchDataRootComponent],
    fileManager: FileManager
  ) throws -> [InventoryEntry] {
    var entries: [InventoryEntry] = []
    for component in components {
      let payloadItems = try migrationPayloadItems(
        for: component,
        layout: layout,
        fileManager: fileManager
      )
      for item in payloadItems {
        try appendInventory(
          for: item.url,
          relativeTo: layout.rootURL,
          fileManager: fileManager,
          entries: &entries
        )
      }
    }
    return entries.sorted { $0.relativePath < $1.relativePath }
  }

  func appendInventory(
    for payloadURL: URL,
    relativeTo rootURL: URL,
    fileManager: FileManager,
    entries: inout [InventoryEntry]
  ) throws {
    entries.append(
      try inventoryEntry(
        for: payloadURL,
        relativeTo: rootURL,
        fileManager: fileManager
      )
    )
    guard isDirectory(at: payloadURL) else { return }
    guard let enumerator = fileManager.enumerator(
      at: payloadURL,
        includingPropertiesForKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey
        ],
        options: []
    ) else {
      throw WorkbenchDataRootMigrationError.unsupportedFilesystemItem(
        relativePath(of: payloadURL, within: rootURL)
      )
    }
    for case let childURL as URL in enumerator {
      entries.append(
        try inventoryEntry(
          for: childURL,
          relativeTo: rootURL,
          fileManager: fileManager
        )
      )
    }
  }

  func migrationPayloadItems(
    for component: WorkbenchDataRootComponent,
    layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> [MigrationPayloadItem] {
    if component == .workbench {
      return try existingWorkbenchPayloadItems(in: layout, fileManager: fileManager)
    }
    let url = layout.componentURL(for: component)
    guard itemExists(at: url, fileManager: fileManager) else { return [] }
    return [
      MigrationPayloadItem(
        url: url,
        expectedKind: component == .workbench ? .regularFile : .directory
      )
    ]
  }

  func existingWorkbenchPayloadItems(
    in layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> [MigrationPayloadItem] {
    let persistence = WorkbenchPersistence(fileURL: layout.workbenchFileURL)
    let operationLedgerPersistence = WorkbenchOperationLedgerPersistence(
      fileURL: persistence.operationLedgerURL
    )
    // Automatic backups and completed recovery points are durable user data.
    // Root-level pending, applying, and transaction items are intentionally not
    // candidates: they could trigger an unintended restore in the new root.
    var candidates = [
      MigrationPayloadItem(url: persistence.fileURL, expectedKind: .regularFile),
      MigrationPayloadItem(url: persistence.lastKnownGoodURL, expectedKind: .regularFile),
      MigrationPayloadItem(url: persistence.draftRecoveryJournalURL, expectedKind: .regularFile),
      MigrationPayloadItem(
        url: operationLedgerPersistence.fileURL,
        expectedKind: .regularFile
      ),
      MigrationPayloadItem(
        url: operationLedgerPersistence.lastKnownGoodURL,
        expectedKind: .regularFile
      ),
      MigrationPayloadItem(url: persistence.recoveryArchiveDirectoryURL, expectedKind: .directory),
      MigrationPayloadItem(url: persistence.retiredFeatureArchiveDirectoryURL, expectedKind: .directory),
      MigrationPayloadItem(url: persistence.imageOptimizationDirectoryURL, expectedKind: .directory),
      MigrationPayloadItem(
        url: layout.rootURL.appendingPathComponent(
          WorkspaceBackupService.automaticBackupDirectoryName,
          isDirectory: true
        ),
        expectedKind: .directory
      ),
      MigrationPayloadItem(
        url: layout.rootURL.appendingPathComponent(
          "KnowledgeLibraryRecovery",
          isDirectory: true
        ),
        expectedKind: .directory
      ),
      MigrationPayloadItem(
        url: layout.rootURL.appendingPathComponent(
          "WorkspaceBackupRecovery",
          isDirectory: true
        ),
        expectedKind: .directory
      ),
    ]

    let quarantinePrefixes = [
      persistence.draftRecoveryJournalURL.deletingPathExtension().lastPathComponent
        + ".unreadable-",
      operationLedgerPersistence.fileURL.deletingPathExtension().lastPathComponent
        + ".unreadable-",
      operationLedgerPersistence.lastKnownGoodURL.deletingPathExtension().lastPathComponent
        + ".unreadable-",
    ]
    let rootItems = try fileManager.contentsOfDirectory(
      at: layout.rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    )
    candidates.append(
      contentsOf: rootItems.compactMap { url in
        let name = url.lastPathComponent
        guard quarantinePrefixes.contains(where: name.hasPrefix), name.hasSuffix(".json") else {
          return nil
        }
        return MigrationPayloadItem(url: url, expectedKind: .regularFile)
      })
    return
      candidates
      .filter { itemExists(at: $0.url, fileManager: fileManager) }
      .sorted { $0.url.path < $1.url.path }
  }

  func inventoryEntry(
    for url: URL,
    relativeTo rootURL: URL,
    fileManager: FileManager
  ) throws -> InventoryEntry {
    let relativePath = relativePath(of: url, within: rootURL)
    let values = try url.resourceValues(
      forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isSymbolicLink != true,
          !isSymbolicLink(at: url, fileManager: fileManager) else {
      throw WorkbenchDataRootMigrationError.unsupportedFilesystemItem(relativePath)
    }
    if values.isDirectory == true {
      return InventoryEntry(
        relativePath: relativePath,
        kind: .directory,
        byteCount: 0,
        sha256: nil
      )
    }
    if values.isRegularFile == true {
      return InventoryEntry(
        relativePath: relativePath,
        kind: .regularFile,
        byteCount: Int64(values.fileSize ?? 0),
        sha256: try sha256(of: url)
      )
    }
    throw WorkbenchDataRootMigrationError.unsupportedFilesystemItem(relativePath)
  }

  func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var digest = SHA256()
    while true {
      let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
      if data.isEmpty { break }
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func relativePath(of url: URL, within rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let itemPath = url.standardizedFileURL.path
    guard itemPath.hasPrefix(rootPath + "/") else { return itemPath }
    return String(itemPath.dropFirst(rootPath.count + 1))
  }

  func itemExists(at url: URL, fileManager: FileManager) -> Bool {
    if fileManager.fileExists(atPath: url.path) {
      return true
    }
    return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
    if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      return true
    }
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  func isRegularFile(at url: URL) -> Bool {
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      return false
    }
    return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  func isDirectory(at url: URL) -> Bool {
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      return false
    }
    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
