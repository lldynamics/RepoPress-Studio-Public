import CryptoKit
import Foundation

extension WorkspaceBackupService {
  func validatedBackup(
    at packageURL: URL,
    currentApplicationVersion: String? = nil
  ) throws -> ValidatedBackup {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw WorkspaceBackupError.sourceUnavailable(packageURL.path)
    }
    let packageValues = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard packageValues.isSymbolicLink != true else {
      throw WorkspaceBackupError.invalidPath(packageURL.path)
    }

    let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
    let manifestData = try boundedData(
      at: manifestURL,
      maximumByteCount: limits.maximumManifestByteCount,
      relativePath: Self.manifestFileName
    )
    let manifest: WorkspaceBackupManifest
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      manifest = try decoder.decode(WorkspaceBackupManifest.self, from: manifestData)
    } catch {
      throw WorkspaceBackupError.invalidManifest(error.localizedDescription)
    }
    guard manifest.formatVersion >= WorkspaceBackupManifest.minimumSupportedFormatVersion,
          manifest.formatVersion <= WorkspaceBackupManifest.currentFormatVersion else {
      throw WorkspaceBackupError.unsupportedFormat(manifest.formatVersion)
    }
    guard !manifest.includesAPIKeys else {
      throw WorkspaceBackupError.apiKeysNotAllowed
    }
    guard manifest.fileCount == manifest.files.count else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("文件数量与清单不一致"))
    }
    guard manifest.attachmentReferenceCount == manifest.attachmentReferences.count else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("附件引用数量与清单不一致")
      )
    }

    var seenPaths = Set<String>()
    for record in manifest.files {
      try validateRelativePath(record.relativePath)
      guard seenPaths.insert(record.relativePath).inserted else {
        throw WorkspaceBackupError.invalidManifest(
          CoreL10n.format("文件路径重复：%@", record.relativePath)
        )
      }
      guard component(for: record.relativePath) == record.component else {
        throw WorkspaceBackupError.invalidManifest(
          CoreL10n.format("组件与文件路径不一致：%@", record.relativePath)
        )
      }
      let actual = try fileRecord(
        relativePath: record.relativePath,
        component: record.component,
        under: packageURL
      )
      guard actual.sha256 == record.sha256.lowercased() else {
        throw WorkspaceBackupError.checksumMismatch(record.relativePath)
      }
      guard actual.byteCount == record.byteCount else {
        throw WorkspaceBackupError.fileSizeMismatch(record.relativePath)
      }
    }
    let declaredTotalByteCount = try validateFileLimits(manifest.files)
    guard declaredTotalByteCount == manifest.totalByteCount else {
      throw WorkspaceBackupError.invalidManifest(CoreL10n.text("总大小与文件清单不一致"))
    }
    let actualPaths = try regularFilePaths(in: packageURL).filter {
      $0 != Self.manifestFileName
    }
    guard Set(actualPaths) == seenPaths else {
      let missing = seenPaths.subtracting(actualPaths).sorted()
      let extra = Set(actualPaths).subtracting(seenPaths).sorted()
      let missingSummary = missing.joined(separator: ", ").nilIfEmpty ?? CoreL10n.text("无")
      let extraSummary = extra.joined(separator: ", ").nilIfEmpty ?? CoreL10n.text("无")
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.format(
          "实际文件与清单不同；缺少 %@，多出 %@",
          missingSummary,
          extraSummary
        )
      )
    }
    guard manifest.components == componentSummaries(
      for: manifest.files,
      formatVersion: manifest.formatVersion
    ) else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("组件统计与文件清单不一致")
      )
    }

    let workbenchData = try boundedData(
      at: packageURL.appendingPathComponent(Self.workbenchRelativePath),
      maximumByteCount: Int(limits.maximumWorkbenchByteCount),
      relativePath: Self.workbenchRelativePath
    )
    let snapshot: WorkbenchSnapshot
    do {
      snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: workbenchData)
      try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    } catch {
      throw WorkspaceBackupError.invalidWorkbenchSnapshot(error.localizedDescription)
    }
    try validateAttachmentReferences(
      in: snapshot,
      references: manifest.attachmentReferences,
      files: manifest.files
    )
    guard manifest.profileCount == snapshot.profiles.count,
          manifest.draftCount == snapshot.drafts.count,
          manifest.draftVersionCount == snapshot.draftVersions.count,
          manifest.releaseRecordCount == snapshot.releaseRecords.count,
          manifest.unresolvedAttachmentCount == unresolvedAttachmentCount(in: snapshot)
    else {
      throw WorkspaceBackupError.invalidManifest(
        CoreL10n.text("工作区数据统计与快照不一致")
      )
    }

    let knowledgeURL = packageURL.appendingPathComponent(Self.knowledgePackageName)
    do {
      _ = try KnowledgeLibraryBackupService(
        rootURL: knowledgeURL,
        fileManager: fileManager
      ).inspectBackup(at: knowledgeURL)
    } catch {
      throw WorkspaceBackupError.knowledgeLibraryInvalid(error.localizedDescription)
    }

    if manifest.formatVersion >= 2 {
      do {
        _ = try RSSReaderBackupService(fileManager: fileManager).inspectBackup(
          at: packageURL.appendingPathComponent(Self.rssDatabaseRelativePath)
        )
      } catch {
        throw WorkspaceBackupError.rssReaderInvalid(error.localizedDescription)
      }
    }

    let preview = WorkspaceBackupPreview(
      backupURL: packageURL,
      createdAt: manifest.createdAt,
      applicationVersion: manifest.applicationVersion,
      formatVersion: manifest.formatVersion,
      compatibility: compatibility(
        backupApplicationVersion: manifest.applicationVersion,
        currentApplicationVersion: currentApplicationVersion
      ),
      includesAPIKeys: manifest.includesAPIKeys,
      profileCount: manifest.profileCount,
      draftCount: manifest.draftCount,
      draftVersionCount: manifest.draftVersionCount,
      releaseRecordCount: manifest.releaseRecordCount,
      attachmentReferenceCount: manifest.attachmentReferenceCount,
      unresolvedAttachmentCount: manifest.unresolvedAttachmentCount,
      components: manifest.components,
      fileCount: manifest.fileCount,
      totalByteCount: manifest.totalByteCount
    )
    return ValidatedBackup(manifest: manifest, snapshot: snapshot, preview: preview)
  }

  func compatibility(
    backupApplicationVersion: String,
    currentApplicationVersion: String?
  ) -> WorkspaceBackupCompatibility {
    guard let currentApplicationVersion,
          let backupComponents = versionComponents(backupApplicationVersion),
          let currentComponents = versionComponents(currentApplicationVersion) else {
      return .unknownApplicationVersion
    }
    if backupComponents == currentComponents {
      return .compatible
    }
    return backupComponents.lexicographicallyPrecedes(currentComponents)
      ? .createdByOlderApplication
      : .createdByNewerApplication
  }

  func versionComponents(_ rawVersion: String) -> [Int]? {
    let components = rawVersion.split { character in
      !character.isNumber
    }
    let numbers = components.compactMap { Int($0) }
    guard !numbers.isEmpty else {
      return nil
    }
    var normalized = numbers
    while normalized.last == 0, normalized.count > 1 {
      normalized.removeLast()
    }
    return normalized
  }

  func validateAttachmentReferences(
    in snapshot: WorkbenchSnapshot,
    references: [WorkspaceBackupAttachmentReference],
    files: [WorkspaceBackupFileRecord]
  ) throws {
    var markers = Set<String>()
    var archivePaths = Set<String>()
    var restoredPaths = Set<String>()
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) })
    for reference in references {
      guard reference.marker.hasPrefix(Self.attachmentMarkerPrefix),
            reference.marker.dropFirst(Self.attachmentMarkerPrefix.count).isEmpty == false,
            markers.insert(reference.marker).inserted else {
        throw WorkspaceBackupError.invalidAttachmentReference(reference.marker)
      }
      try validateRelativePath(reference.archiveRelativePath)
      try validateRelativePath(reference.restoredRelativePath)
      guard reference.archiveRelativePath.hasPrefix(Self.attachmentsDirectoryName + "/"),
            reference.restoredRelativePath.hasPrefix("WorkspaceBackup/"),
            filesByPath[reference.archiveRelativePath]?.component == .draftAttachments,
            archivePaths.insert(reference.archiveRelativePath).inserted,
            restoredPaths.insert(reference.restoredRelativePath).inserted else {
        throw WorkspaceBackupError.invalidAttachmentReference(reference.marker)
      }
    }
    for attachment in allAttachments(in: snapshot) {
      guard let sourcePath = attachment.sourceFilePath,
            !sourcePath.isEmpty else {
        continue
      }
      guard sourcePath.hasPrefix(Self.attachmentMarkerPrefix),
            markers.contains(sourcePath) else {
        throw WorkspaceBackupError.invalidAttachmentReference(sourcePath)
      }
    }
  }

  func unresolvedAttachmentCount(in snapshot: WorkbenchSnapshot) -> Int {
    allAttachments(in: snapshot).reduce(into: 0) { count, attachment in
      guard let sourcePath = attachment.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sourcePath.isEmpty else {
        count += 1
        return
      }
    }
  }

  func component(for relativePath: String) -> WorkspaceBackupComponent? {
    if relativePath == Self.workbenchRelativePath { return .workbenchState }
    if relativePath.hasPrefix(Self.attachmentsDirectoryName + "/") {
      return .draftAttachments
    }
    if relativePath.hasPrefix(Self.knowledgePackageName + "/") {
      return .knowledgeLibrary
    }
    if relativePath == Self.rssDatabaseRelativePath
      || relativePath.hasPrefix(Self.rssMediaRelativePrefix + "/") {
      return .rssReader
    }
    return nil
  }

  func componentSummaries(
    for records: [WorkspaceBackupFileRecord],
    formatVersion: Int
  ) -> [WorkspaceBackupComponentSummary] {
    let components = WorkspaceBackupComponent.allCases.filter { component in
      formatVersion >= 2 || component != .rssReader
    }
    return components.map { component in
      let matching = records.filter { $0.component == component }
      return WorkspaceBackupComponentSummary(
        component: component,
        fileCount: matching.count,
        byteCount: matching.reduce(0) { $0 + $1.byteCount }
      )
    }
  }

  func recordsInDirectory(
    _ directoryURL: URL,
    relativePrefix: String,
    component: WorkspaceBackupComponent,
    under rootURL: URL
  ) throws -> [WorkspaceBackupFileRecord] {
    let files = try regularFileURLs(in: directoryURL)
    return try files.map { fileURL in
      let relativePath = try relativePath(of: fileURL, under: rootURL)
      guard relativePath.hasPrefix(relativePrefix + "/") else {
        throw WorkspaceBackupError.invalidPath(relativePath)
      }
      return try fileRecord(
        relativePath: relativePath,
        component: component,
        under: rootURL
      )
    }
  }

  func regularFilePaths(in directoryURL: URL) throws -> [String] {
    try regularFileURLs(in: directoryURL).map {
      try relativePath(of: $0, under: directoryURL)
    }
  }

  func regularFileURLs(in directoryURL: URL) throws -> [URL] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      throw WorkspaceBackupError.sourceUnavailable(directoryURL.path)
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true else {
        throw WorkspaceBackupError.invalidPath(url.path)
      }
      if values.isDirectory == true { continue }
      guard values.isRegularFile == true else {
        throw WorkspaceBackupError.invalidPath(url.path)
      }
      files.append(url)
    }
    return files.sorted { $0.path < $1.path }
  }

  func relativePath(of fileURL: URL, under rootURL: URL) throws -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else {
      throw WorkspaceBackupError.invalidPath(filePath)
    }
    let relativePath = String(filePath.dropFirst(prefix.count))
    try validateRelativePath(relativePath)
    return relativePath
  }

  func validateRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          !path.contains("\0"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw WorkspaceBackupError.invalidPath(path)
    }
  }

  func fileRecord(
    relativePath: String,
    component: WorkspaceBackupComponent,
    under rootURL: URL
  ) throws -> WorkspaceBackupFileRecord {
    try validateRelativePath(relativePath)
    let url = rootURL.appendingPathComponent(relativePath)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    let byteCount = try fileSize(of: url, relativePath: relativePath)
    guard byteCount <= limits.maximumSingleFileByteCount else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: limits.maximumSingleFileByteCount
      )
    }
    return WorkspaceBackupFileRecord(
      relativePath: relativePath,
      component: component,
      byteCount: byteCount,
      sha256: try sha256(of: url, relativePath: relativePath)
    )
  }
}
