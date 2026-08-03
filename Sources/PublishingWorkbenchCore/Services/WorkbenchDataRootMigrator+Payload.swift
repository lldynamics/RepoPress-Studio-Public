import Foundation

extension WorkbenchDataRootMigrator {
  func copyComponents(
    _ preparation: Preparation,
    to stagingLayout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws {
    for component in preparation.components {
      let payloadItems = try migrationPayloadItems(
        for: component,
        layout: preparation.sourceLayout,
        fileManager: fileManager
      )
      for item in payloadItems {
        let relativePath = relativePath(
          of: item.url,
          within: preparation.sourceLayout.rootURL
        )
        guard !relativePath.hasPrefix("/") else {
          throw WorkbenchDataRootMigrationError.unsupportedFilesystemItem(relativePath)
        }
        try fileManager.copyItem(
          at: item.url,
          to: stagingLayout.rootURL.appendingPathComponent(
            relativePath,
            isDirectory: item.expectedKind == .directory
          )
        )
      }
    }
  }

  func discoverComponents(
    in layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) throws -> [WorkbenchDataRootComponent] {
    var components: [WorkbenchDataRootComponent] = []
    for component in WorkbenchDataRootComponent.allCases {
      let payloadItems = try migrationPayloadItems(
        for: component,
        layout: layout,
        fileManager: fileManager
      )
      guard !payloadItems.isEmpty else { continue }

      let hasExpectedType = payloadItems.allSatisfy { item in
        switch item.expectedKind {
        case .regularFile:
          return isRegularFile(at: item.url)
        case .directory:
          return isDirectory(at: item.url)
        }
      } && (component != .rssReader || isRegularFile(at: layout.rssReaderDatabaseURL))
      guard hasExpectedType else {
        throw WorkbenchDataRootMigrationError.sourceComponentHasUnexpectedType(component)
      }
      components.append(component)
    }
    return components.sorted { $0.rawValue < $1.rawValue }
  }

  func rewriteAppOwnedAttachmentPaths(
    in stagingLayout: WorkbenchDataRootLayout,
    from sourceRootURL: URL,
    to destinationRootURL: URL,
    fileManager: FileManager
  ) throws {
    let persistence = WorkbenchPersistence(fileURL: stagingLayout.workbenchFileURL)
    for snapshotURL in [persistence.fileURL, persistence.lastKnownGoodURL]
    where fileManager.fileExists(atPath: snapshotURL.path) {
      try rewriteAttachmentPathsIfValidSnapshot(
        at: snapshotURL,
        from: sourceRootURL,
        to: destinationRootURL
      )
    }
    // WorkspaceBackupRecovery snapshots retain their original bytes because
    // their attachments live inside each recovery point, not in the live root.
    try rewriteRecoveryArchiveAttachmentPaths(
      in: persistence.recoveryArchiveDirectoryURL,
      from: sourceRootURL,
      to: destinationRootURL,
      fileManager: fileManager
    )
  }

  func rewriteRecoveryArchiveAttachmentPaths(
    in recoveryRootURL: URL,
    from sourceRootURL: URL,
    to destinationRootURL: URL,
    fileManager: FileManager
  ) throws {
    guard fileManager.fileExists(atPath: recoveryRootURL.path) else { return }
    guard let enumerator = fileManager.enumerator(
      at: recoveryRootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []
    ) else {
      return
    }
    let snapshotNames = Set([
      "workbench.json",
      "workbench.last-known-good.json"
    ])
    for case let url as URL in enumerator where snapshotNames.contains(url.lastPathComponent) {
      try rewriteAttachmentPathsIfValidSnapshot(
        at: url,
        from: sourceRootURL,
        to: destinationRootURL
      )
    }
  }

  func rewriteAttachmentPathsIfValidSnapshot(
    at snapshotURL: URL,
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) throws {
    let originalData = try BoundedFileReader.data(
      at: snapshotURL,
      maximumByteCount: WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount
    )
    guard let snapshot = try? JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: originalData
    ), (try? WorkbenchSnapshotSemanticValidator.validate(snapshot)) != nil else {
      return
    }
    guard var object = try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
    else {
      return
    }
    guard rewriteSnapshotAttachmentPaths(
      in: &object,
      from: sourceRootURL,
      to: destinationRootURL
    ) else {
      return
    }

    let rewrittenData = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    let rewrittenSnapshot = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: rewrittenData
    )
    try WorkbenchSnapshotSemanticValidator.validate(rewrittenSnapshot)
    try rewrittenData.write(to: snapshotURL, options: .atomic)
  }

  func rewriteSnapshotAttachmentPaths(
    in snapshot: inout [String: Any],
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) -> Bool {
    var changed = rewriteDrafts(
      in: &snapshot,
      key: "drafts",
      from: sourceRootURL,
      to: destinationRootURL
    )
    changed = rewriteNestedDrafts(
      in: &snapshot,
      key: "recycledDrafts",
      from: sourceRootURL,
      to: destinationRootURL
    ) || changed
    changed = rewriteNestedDrafts(
      in: &snapshot,
      key: "draftVersions",
      from: sourceRootURL,
      to: destinationRootURL
    ) || changed
    return changed
  }

  func rewriteDrafts(
    in snapshot: inout [String: Any],
    key: String,
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) -> Bool {
    guard var drafts = snapshot[key] as? [[String: Any]] else { return false }
    var changed = false
    for index in drafts.indices {
      changed = rewriteDraftAttachmentPaths(
        in: &drafts[index],
        from: sourceRootURL,
        to: destinationRootURL
      ) || changed
    }
    snapshot[key] = drafts
    return changed
  }

  func rewriteNestedDrafts(
    in snapshot: inout [String: Any],
    key: String,
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) -> Bool {
    guard var records = snapshot[key] as? [[String: Any]] else { return false }
    var changed = false
    for index in records.indices {
      guard var draft = records[index]["draft"] as? [String: Any] else { continue }
      let draftChanged = rewriteDraftAttachmentPaths(
        in: &draft,
        from: sourceRootURL,
        to: destinationRootURL
      )
      records[index]["draft"] = draft
      changed = draftChanged || changed
    }
    snapshot[key] = records
    return changed
  }

  func rewriteDraftAttachmentPaths(
    in draft: inout [String: Any],
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) -> Bool {
    guard var attachments = draft["attachments"] as? [[String: Any]] else { return false }
    var changed = false
    for index in attachments.indices {
      guard let path = attachments[index]["sourceFilePath"] as? String,
            let relocatedPath = relocatedAppOwnedPath(
              path,
              from: sourceRootURL,
              to: destinationRootURL
            ) else {
        continue
      }
      attachments[index]["sourceFilePath"] = relocatedPath
      changed = true
    }
    draft["attachments"] = attachments
    return changed
  }

  func relocatedAppOwnedPath(
    _ path: String,
    from sourceRootURL: URL,
    to destinationRootURL: URL
  ) -> String? {
    guard NSString(string: path).isAbsolutePath else { return nil }
    let sourceRootPath = sourceRootURL.standardizedFileURL.path
    let sourcePrefix = sourceRootPath.hasSuffix("/") ? sourceRootPath : sourceRootPath + "/"
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    guard standardizedPath.hasPrefix(sourcePrefix) else { return nil }
    let relativePath = String(standardizedPath.dropFirst(sourcePrefix.count))
    guard let firstComponent = relativePath.split(separator: "/").first,
          firstComponent == "ManagedAttachments" || firstComponent == "OptimizedImages"
    else {
      return nil
    }
    return destinationRootURL
      .appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL
      .path
  }
}
