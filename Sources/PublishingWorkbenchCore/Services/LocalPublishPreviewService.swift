import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PublishFileDiffStatus: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case unchanged
  case missingSource
  case unsafePath

  public var displayName: String {
    switch self {
    case .added:
      return "新增"
    case .modified:
      return "修改"
    case .deleted:
      return "删除"
    case .unchanged:
      return "未变化"
    case .missingSource:
      return "源文件缺失"
    case .unsafePath:
      return "路径不安全"
    }
  }
}

public struct LocalPublishSourceFileState: Codable, Hashable, Sendable {
  public var byteSize: Int64
  public var sha256: Data
  public var deviceIdentifier: UInt64
  public var fileIdentifier: UInt64

  public init(
    byteSize: Int64,
    sha256: Data,
    deviceIdentifier: UInt64,
    fileIdentifier: UInt64
  ) {
    self.byteSize = byteSize
    self.sha256 = sha256
    self.deviceIdentifier = deviceIdentifier
    self.fileIdentifier = fileIdentifier
  }
}

public struct PublishFileDiff: Identifiable, Codable, Hashable, Sendable {
  public var id: String { path }
  public var path: String
  public var kind: PublishFileKind
  public var status: PublishFileDiffStatus
  public var lineDiff: String?
  public var byteSize: Int64
  public var baselineState: LocalPublishFileState?
  public var sourceState: LocalPublishSourceFileState?

  public init(
    path: String,
    kind: PublishFileKind,
    status: PublishFileDiffStatus,
    lineDiff: String? = nil,
    byteSize: Int64 = 0,
    baselineState: LocalPublishFileState? = nil,
    sourceState: LocalPublishSourceFileState? = nil
  ) {
    self.path = path
    self.kind = kind
    self.status = status
    self.lineDiff = lineDiff
    self.byteSize = byteSize
    self.baselineState = baselineState
    self.sourceState = sourceState
  }
}

public struct LocalPublishPreview: Codable, Hashable, Sendable {
  public var package: PublishPackage
  public var fileDiffs: [PublishFileDiff]
  public var issues: [PreflightIssue]
  public var generatedAt: Date

  public init(
    package: PublishPackage,
    fileDiffs: [PublishFileDiff],
    issues: [PreflightIssue],
    generatedAt: Date = Date()
  ) {
    self.package = package
    self.fileDiffs = fileDiffs
    self.issues = issues
    self.generatedAt = generatedAt
  }

  public var changedFileDiffs: [PublishFileDiff] {
    fileDiffs.filter { $0.status != .unchanged }
  }
}

public struct LocalPublishPreviewService: Sendable {
  private let fileSystem: SendableFileManager

  private var fileManager: FileManager { fileSystem.value }

  public init(fileManager: FileManager = .default) {
    self.fileSystem = SendableFileManager(fileManager)
  }

  public func preview(package: PublishPackage, profile: SiteProfile) -> LocalPublishPreview {
    guard let preview = profile.withLocalRepositoryRootAccess({ rootURL in
      preview(package: package, rootURL: rootURL)
    }) else {
      return missingRepositoryPreview(package: package)
    }

    return preview
  }

  /// Generates the same preview as ``preview(package:profile:)`` without
  /// performing repository traversal or file reads on the caller's executor.
  ///
  /// The synchronous implementation is invoked entirely inside the detached
  /// task so security-scoped repository access starts, is used, and stops on
  /// the same detached operation.
  public func previewAsync(package: PublishPackage, profile: SiteProfile) async -> LocalPublishPreview {
    await Task.detached(priority: .userInitiated) {
      preview(package: package, profile: profile)
    }.value
  }

  func preview(package: PublishPackage, rootURL: URL) -> LocalPublishPreview {
    var diffs: [PublishFileDiff] = []
    var issues: [PreflightIssue] = []

    for file in package.files {
      guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: file.repositoryPath) else {
        diffs.append(
          PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .unsafePath, byteSize: file.byteSize)
        )
        issues.append(
          .init(
            severity: .error,
            title: CoreL10n.text("发布路径不安全"),
            message: file.repositoryPath,
            field: "repositoryPath"
          )
        )
        continue
      }

      let baselineState: LocalPublishFileState
      do {
        baselineState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
      } catch {
        diffs.append(
          PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .unsafePath, byteSize: file.byteSize)
        )
        issues.append(
          .init(
            severity: .error,
            title: CoreL10n.text("无法读取发布目标"),
            message: file.repositoryPath,
            field: "repositoryPath"
          )
        )
        continue
      }

      if file.operation == .delete {
        let exists = baselineState != .missing

        let existingContent: String
        if file.kind == .markdown, exists {
          do {
            existingContent = try readExistingMarkdownContent(at: destinationURL)
          } catch {
            diffs.append(
              PublishFileDiff(
                path: file.repositoryPath,
                kind: file.kind,
                status: .deleted,
                byteSize: file.byteSize,
                baselineState: nil
              )
            )
            issues.append(
              unreadableMarkdownIssue(
                repositoryPath: file.repositoryPath,
                error: error
              )
            )
            continue
          }
        } else {
          existingContent = ""
        }
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: exists ? .deleted : .unchanged,
            lineDiff: exists && file.kind == .markdown
              ? unifiedDiff(old: existingContent, new: "")
              : nil,
            baselineState: baselineState
          )
        )
        continue
      }

      switch file.kind {
      case .markdown:
        let newContent = file.content ?? ""
        let exists = baselineState != .missing
        let existingContent: String
        if exists {
          do {
            existingContent = try readExistingMarkdownContent(at: destinationURL)
          } catch {
            diffs.append(
              PublishFileDiff(
                path: file.repositoryPath,
                kind: file.kind,
                status: .modified,
                byteSize: Int64(newContent.utf8.count),
                baselineState: nil
              )
            )
            issues.append(
              unreadableMarkdownIssue(
                repositoryPath: file.repositoryPath,
                error: error
              )
            )
            continue
          }
        } else {
          existingContent = ""
        }
        let status: PublishFileDiffStatus = exists
          ? (existingContent == newContent ? .unchanged : .modified)
          : .added
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: status,
            lineDiff: status == .unchanged ? nil : unifiedDiff(old: existingContent, new: newContent),
            byteSize: Int64(newContent.utf8.count),
            baselineState: baselineState
          )
        )
      case .image, .video:
        guard let sourceFilePath = file.sourceFilePath else {
          diffs.append(
            PublishFileDiff(
              path: file.repositoryPath,
              kind: file.kind,
              status: .missingSource,
              byteSize: file.byteSize,
              baselineState: baselineState
            )
          )
          issues.append(.init(
            severity: .error,
            title: CoreL10n.format("%@源文件缺失", file.kind.displayName),
            message: file.repositoryPath,
            field: "attachments"
          ))
          continue
        }

        let sourceState: LocalPublishSourceFileState
        do {
          sourceState = try localPublishSourceFileState(
            at: URL(fileURLWithPath: sourceFilePath),
            repositoryPath: file.repositoryPath
          )
        } catch {
          let status: PublishFileDiffStatus
          let title: String
          if case LocalPublishPreviewError.missingSource = error {
            status = .missingSource
            title = CoreL10n.format("%@源文件缺失", file.kind.displayName)
          } else {
            status = .unsafePath
            title = CoreL10n.format("%@源文件不安全", file.kind.displayName)
          }
          diffs.append(
            PublishFileDiff(
              path: file.repositoryPath,
              kind: file.kind,
              status: status,
              byteSize: file.byteSize,
              baselineState: baselineState
            )
          )
          issues.append(.init(
            severity: .error,
            title: title,
            message: CoreL10n.format("%@：%@", file.repositoryPath, error.localizedDescription),
            field: "attachments"
          ))
          continue
        }

        let exists = baselineState != .missing
        let status: PublishFileDiffStatus
        if !exists {
          status = .added
        } else if baselineState == .fileDigest(sourceState.sha256) {
          status = .unchanged
        } else {
          status = .modified
        }
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: status,
            byteSize: sourceState.byteSize,
            baselineState: baselineState,
            sourceState: sourceState
          )
        )
      }
    }

    return LocalPublishPreview(package: package, fileDiffs: diffs, issues: issues)
  }

  private func readExistingMarkdownContent(at url: URL) throws -> String {
    try BoundedFileReader.utf8String(
      at: url,
      maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
    )
  }

  private func unreadableMarkdownIssue(
    repositoryPath: String,
    error: Error
  ) -> PreflightIssue {
    PreflightIssue(
      severity: .error,
      title: CoreL10n.text("无法读取现有 Markdown 文件"),
      message: CoreL10n.format("%@：%@", repositoryPath, error.localizedDescription),
      field: "repositoryPath"
    )
  }

  public func write(package: PublishPackage, profile: SiteProfile) throws -> [String] {
    guard let writtenPaths = try profile.withLocalRepositoryRootAccess({ rootURL in
      try write(package: package, rootURL: rootURL)
    }) else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    return writtenPaths
  }

  public func write(preview: LocalPublishPreview, profile: SiteProfile) throws -> [String] {
    guard let writtenPaths = try profile.withLocalRepositoryRootAccess({ rootURL in
      try write(preview: preview, rootURL: rootURL)
    }) else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    return writtenPaths
  }

  public func writeAsync(package: PublishPackage, profile: SiteProfile) async throws -> [String] {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    return try await Task.detached(priority: .userInitiated) {
      try write(package: package, rootURL: rootURL)
    }.value
  }

  public func writeAsync(preview: LocalPublishPreview, profile: SiteProfile) async throws -> [String] {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    return try await Task.detached(priority: .userInitiated) {
      try write(preview: preview, rootURL: rootURL)
    }.value
  }

  func write(package: PublishPackage, rootURL: URL) throws -> [String] {
    try writeWithEvidence(package: package, rootURL: rootURL).writtenPaths
  }

  func write(preview: LocalPublishPreview, rootURL: URL) throws -> [String] {
    try writeWithEvidence(
      package: preview.package,
      rootURL: rootURL,
      preview: preview
    ).writtenPaths
  }

  func writeWithEvidence(
    package: PublishPackage,
    rootURL: URL,
    preview: LocalPublishPreview? = nil
  ) throws -> LocalPublishWriteResult {
    let previewBaseStates: [String: LocalPublishFileState]?
    let previewSourceStates: [String: LocalPublishSourceFileState]?
    if let preview {
      previewBaseStates = try expectedBaseStates(for: package, preview: preview)
      previewSourceStates = try expectedSourceStates(for: package, preview: preview)
    } else {
      previewBaseStates = nil
      previewSourceStates = nil
    }
    var seenDestinationPaths = Set<String>()
    let preparedWrites = try package.files.map { file -> PreparedLocalPublishWrite in
      let destinationURL = try validatedDestinationURLForWrite(
        rootURL: rootURL,
        repositoryPath: file.repositoryPath
      )
      guard seenDestinationPaths.insert(destinationURL.path).inserted else {
        throw LocalPublishPreviewError.unsafePath(file.repositoryPath)
      }

      if file.operation == .delete {
        return PreparedLocalPublishWrite(
          file: file,
          destinationURL: destinationURL,
          sourceURL: nil,
          expectedSourceState: nil
        )
      }

      let sourceURL: URL?
      let expectedSourceState: LocalPublishSourceFileState?
      switch file.kind {
      case .markdown:
        sourceURL = nil
        expectedSourceState = nil
      case .image, .video:
        guard let sourceFilePath = file.sourceFilePath else {
          throw LocalPublishPreviewError.missingSource(file.repositoryPath)
        }
        let candidate = URL(fileURLWithPath: sourceFilePath)
        let currentSourceState = try localPublishSourceFileState(
          at: candidate,
          repositoryPath: file.repositoryPath
        )
        let normalizedPath = file.repositoryPath.normalizedRelativePath()
        expectedSourceState = previewSourceStates?[normalizedPath]
        if let expectedSourceState, currentSourceState != expectedSourceState {
          throw LocalPublishPreviewError.sourcePreviewOutdated(file.repositoryPath)
        }
        sourceURL = candidate
      }
      return PreparedLocalPublishWrite(
        file: file,
        destinationURL: destinationURL,
        sourceURL: sourceURL,
        expectedSourceState: expectedSourceState
      )
    }

    for prepared in preparedWrites {
      try validatePreviewBaseline(
        for: prepared.file,
        destinationURL: prepared.destinationURL,
        expectedBaseStates: previewBaseStates
      )
    }

    let rollbackDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("personal-site-publisher-write-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rollbackDirectory) }

    var writtenPaths: [String] = []
    var rollbackEntries: [LocalPublishRollbackEntry] = []
    var appliedStates: [LocalPublishFileState] = []
    do {
      for (index, prepared) in preparedWrites.enumerated() {
        let destinationURL = prepared.file.operation == .delete
          ? prepared.destinationURL
          : try safeDestinationURLForWrite(
            rootURL: rootURL,
            repositoryPath: prepared.file.repositoryPath
          )
        try validatePreviewBaseline(
          for: prepared.file,
          destinationURL: destinationURL,
          expectedBaseStates: previewBaseStates
        )
        let backupURL: URL?
        if fileManager.fileExists(atPath: destinationURL.path) {
          let candidate = rollbackDirectory.appendingPathComponent("\(index)-backup")
          try fileManager.copyItem(at: destinationURL, to: candidate)
          backupURL = candidate
        } else {
          backupURL = nil
        }

        rollbackEntries.append(
          LocalPublishRollbackEntry(
            destinationURL: destinationURL,
            backupURL: backupURL,
            appliedState: nil,
            didMutateDestination: false
          )
        )

        switch prepared.file.operation {
        case .delete:
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
            rollbackEntries[rollbackEntries.count - 1].didMutateDestination = true
          }
        case .upsert:
          switch prepared.file.kind {
          case .markdown:
            try (prepared.file.content ?? "").write(to: destinationURL, atomically: true, encoding: .utf8)
          case .image, .video:
            guard let sourceURL = prepared.sourceURL else {
              throw LocalPublishPreviewError.missingSource(prepared.file.repositoryPath)
            }
            try replaceBinaryFileAtomically(
              sourceURL: sourceURL,
              expectedSourceState: prepared.expectedSourceState,
              destinationURL: destinationURL,
              repositoryPath: prepared.file.repositoryPath
            )
          }
          rollbackEntries[rollbackEntries.count - 1].didMutateDestination = true
        }

        let appliedState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
        rollbackEntries[rollbackEntries.count - 1].appliedState = appliedState
        appliedStates.append(appliedState)
        writtenPaths.append(prepared.file.repositoryPath)
      }
    } catch {
      do {
        try rollbackLocalPublishWrites(rollbackEntries)
      } catch let rollbackError {
        throw LocalPublishPreviewError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      throw error
    }
    return LocalPublishWriteResult(
      writtenPaths: writtenPaths,
      appliedStatesByRepositoryPath: Dictionary(
        uniqueKeysWithValues: zip(
          writtenPaths,
          appliedStates
        )
      )
    )
  }

  public func commitCommand(package: PublishPackage, profile: SiteProfile) -> String? {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return nil
    }

    let paths = package.files
      .map(\.repositoryPath)
      .map(posixShellQuote)
      .joined(separator: " ")
    return "cd \(posixShellQuote(rootPath)) && git add \(paths) && git commit -m \(posixShellQuote(package.commitMessage))"
  }

  private func expectedBaseStates(
    for package: PublishPackage,
    preview: LocalPublishPreview
  ) throws -> [String: LocalPublishFileState] {
    guard preview.package == package else {
      throw LocalPublishPreviewError.invalidPreview("发布包已变化")
    }

    var result: [String: LocalPublishFileState] = [:]
    for file in package.files {
      let normalizedPath = file.repositoryPath.normalizedRelativePath()
      guard result[normalizedPath] == nil,
            let diff = preview.fileDiffs.first(where: {
              $0.path.normalizedRelativePath() == normalizedPath
            }),
            let baselineState = diff.baselineState else {
        throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
      }
      result[normalizedPath] = baselineState
    }
    return result
  }

  private func expectedSourceStates(
    for package: PublishPackage,
    preview: LocalPublishPreview
  ) throws -> [String: LocalPublishSourceFileState] {
    var result: [String: LocalPublishSourceFileState] = [:]
    for file in package.files where file.operation == .upsert && file.kind != .markdown {
      let normalizedPath = file.repositoryPath.normalizedRelativePath()
      guard result[normalizedPath] == nil,
            let diff = preview.fileDiffs.first(where: {
              $0.path.normalizedRelativePath() == normalizedPath
            }),
            let sourceState = diff.sourceState else {
        throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
      }
      result[normalizedPath] = sourceState
    }
    return result
  }

  private func validatePreviewBaseline(
    for file: PublishPackageFile,
    destinationURL: URL,
    expectedBaseStates: [String: LocalPublishFileState]?
  ) throws {
    guard let expectedBaseStates else { return }
    let normalizedPath = file.repositoryPath.normalizedRelativePath()
    guard let expectedState = expectedBaseStates[normalizedPath] else {
      throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
    }
    let currentState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
    guard currentState == expectedState else {
      throw LocalPublishPreviewError.previewOutdated(file.repositoryPath)
    }
  }

  private func missingRepositoryPreview(package: PublishPackage) -> LocalPublishPreview {
    LocalPublishPreview(
      package: package,
      fileDiffs: package.files.map {
        PublishFileDiff(path: $0.repositoryPath, kind: $0.kind, status: .unsafePath, byteSize: $0.byteSize)
      },
      issues: [
        .init(
          severity: .warning,
          title: CoreL10n.text("未选择本地仓库"),
          message: CoreL10n.text("选择仓库后才能生成真实文件 diff。"),
          field: "repository"
        )
      ]
    )
  }

  private func destinationURL(rootURL: URL, repositoryPath: String) -> URL? {
    let relativePath = repositoryPath.normalizedRelativePath()
    guard !relativePath.isEmpty, !relativePath.contains(".."), !repositoryPath.hasPrefix("/") else {
      return nil
    }

    let canonicalRootURL = rootURL.standardizedFileURL
    guard !isSymbolicLink(canonicalRootURL) else {
      return nil
    }

    var destinationURL = canonicalRootURL
    for component in relativePath.split(separator: "/") {
      destinationURL.appendPathComponent(String(component), isDirectory: false)
      // Do not resolve symlinks and compare strings: a repository-owned link
      // could otherwise redirect a write or deletion outside its root.
      guard !isSymbolicLink(destinationURL) else {
        return nil
      }
    }

    let rootPath = canonicalRootURL.path
    guard destinationURL.path == rootPath || destinationURL.path.hasPrefix(rootPath + "/") else {
      return nil
    }
    return destinationURL
  }

  private func safeDestinationURLForWrite(rootURL: URL, repositoryPath: String) throws -> URL {
    guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: repositoryPath) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }

    let rootURL = rootURL.standardizedFileURL
    let relativeComponents = repositoryPath.normalizedRelativePath().split(separator: "/").map(String.init)
    guard relativeComponents.count >= 2 else {
      return destinationURL
    }

    var parentURL = rootURL
    for component in relativeComponents.dropLast() {
      parentURL.appendPathComponent(component, isDirectory: true)
      guard !isSymbolicLink(parentURL) else {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }

      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw LocalPublishPreviewError.unsafePath(repositoryPath)
        }
      } else {
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: false)
      }
    }

    guard !isSymbolicLink(destinationURL) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }
    return destinationURL
  }

  private func validatedDestinationURLForWrite(rootURL: URL, repositoryPath: String) throws -> URL {
    guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: repositoryPath) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }

    let rootURL = rootURL.standardizedFileURL
    let relativeComponents = repositoryPath.normalizedRelativePath().split(separator: "/").map(String.init)
    var parentURL = rootURL
    for component in relativeComponents.dropLast() {
      parentURL.appendPathComponent(component, isDirectory: true)
      guard !isSymbolicLink(parentURL) else {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }
    }

    var destinationIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
       destinationIsDirectory.boolValue {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }
    return destinationURL
  }

  private func replaceBinaryFileAtomically(
    sourceURL: URL,
    expectedSourceState: LocalPublishSourceFileState?,
    destinationURL: URL,
    repositoryPath: String
  ) throws {
    let stagingURL = destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent(".\(destinationURL.lastPathComponent).publisher-stage-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: stagingURL) }

#if canImport(Darwin)
    let stagingDescriptor = stagingURL.path.withCString {
      Darwin.open(
        $0,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
      )
    }
    guard stagingDescriptor >= 0 else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }
    var stagingDescriptorIsOpen = true
    defer {
      if stagingDescriptorIsOpen {
        Darwin.close(stagingDescriptor)
      }
    }

    let copiedSourceState = try withLocalPublishSourceDescriptor(
      at: sourceURL,
      repositoryPath: repositoryPath
    ) { sourceDescriptor in
      try readLocalPublishSource(
        descriptor: sourceDescriptor,
        repositoryPath: repositoryPath,
        destinationDescriptor: stagingDescriptor
      )
    }
    if let expectedSourceState, copiedSourceState != expectedSourceState {
      throw LocalPublishPreviewError.sourcePreviewOutdated(repositoryPath)
    }
    guard Darwin.fsync(stagingDescriptor) == 0 else {
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }
    Darwin.close(stagingDescriptor)
    stagingDescriptorIsOpen = false
#else
    let data = try BoundedFileReader.data(
      at: sourceURL,
      maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
    )
    let copiedSourceState = try localPublishSourceFileState(
      at: sourceURL,
      repositoryPath: repositoryPath
    )
    guard expectedSourceState == nil || copiedSourceState == expectedSourceState else {
      throw LocalPublishPreviewError.sourcePreviewOutdated(repositoryPath)
    }
    try data.write(to: stagingURL, options: .withoutOverwriting)
#endif

    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
  }

  private func rollbackLocalPublishWrites(_ entries: [LocalPublishRollbackEntry]) throws {
    for entry in entries.reversed() {
      guard entry.didMutateDestination else { continue }
      guard let appliedState = entry.appliedState else {
        throw LocalPublishPreviewError.rollbackConflict(entry.destinationURL.path)
      }
      let currentState = try localPublishFileState(at: entry.destinationURL, fileManager: fileManager)
      guard currentState == appliedState else {
        throw LocalPublishPreviewError.rollbackConflict(entry.destinationURL.path)
      }
      if fileManager.fileExists(atPath: entry.destinationURL.path) {
        try fileManager.removeItem(at: entry.destinationURL)
      }
      if let backupURL = entry.backupURL {
        try fileManager.copyItem(at: backupURL, to: entry.destinationURL)
      }
    }
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    // destinationOfSymbolicLink catches dangling links too, unlike fileExists.
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func unifiedDiff(old: String, new: String) -> String {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lines: [String] = ["--- repository", "+++ publish-package"]
    let maxCount = max(oldLines.count, newLines.count)
    let changedIndexes = Set((0..<maxCount).filter { index in
      let oldLine = index < oldLines.count ? oldLines[index] : nil
      let newLine = index < newLines.count ? newLines[index] : nil
      return oldLine != newLine
    })
    let contextRadius = 3
    let includedIndexes = Set(changedIndexes.flatMap { changedIndex in
      max(0, changedIndex - contextRadius)...min(maxCount - 1, changedIndex + contextRadius)
    })
    var skippedUnchangedLineCount = 0

    for index in 0..<maxCount {
      guard includedIndexes.contains(index) else {
        skippedUnchangedLineCount += 1
        continue
      }
      if skippedUnchangedLineCount > 0 {
        lines.append(" ... \(skippedUnchangedLineCount) unchanged line(s) ...")
        skippedUnchangedLineCount = 0
      }
      let oldLine = index < oldLines.count ? oldLines[index] : nil
      let newLine = index < newLines.count ? newLines[index] : nil
      if oldLine == newLine {
        if let oldLine {
          lines.append(" \(oldLine)")
        }
      } else {
        if let oldLine {
          lines.append("-\(oldLine)")
        }
        if let newLine {
          lines.append("+\(newLine)")
        }
      }
    }
    if skippedUnchangedLineCount > 0 {
      lines.append(" ... \(skippedUnchangedLineCount) unchanged line(s) ...")
    }

    return lines.joined(separator: "\n")
  }
}

public enum LocalPublishPreviewError: LocalizedError {
  case missingRepositoryRoot
  case unsafePath(String)
  case missingSource(String)
  case unsafeSource(String)
  case invalidPreview(String)
  case previewOutdated(String)
  case sourcePreviewOutdated(String)
  case rollbackConflict(String)
  case rollbackFailed(original: String, rollback: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      return CoreL10n.text("未选择本地仓库。")
    case .unsafePath(let path):
      return CoreL10n.format("发布路径不安全：%@", path)
    case .missingSource(let path):
      return CoreL10n.format("源文件缺失：%@", path)
    case .unsafeSource(let path):
      return CoreL10n.format("源文件不是可安全读取的普通文件：%@", path)
    case .invalidPreview(let path):
      return CoreL10n.format("发布预览缺少有效的文件基线，请重新生成预览：%@", path)
    case .previewOutdated(let path):
      return CoreL10n.format("目标文件在预览后已被外部修改，已停止写入：%@", path)
    case .sourcePreviewOutdated(let path):
      return CoreL10n.format("媒体源文件在预览后已变化，已停止写入：%@", path)
    case .rollbackConflict(let path):
      return CoreL10n.format("检测到外部修改，已停止自动恢复并保留当前文件：%@", path)
    case .rollbackFailed(let original, let rollback):
      return CoreL10n.format(
        "本地写入失败，且自动恢复未完整完成：%@；恢复错误：%@",
        original,
        rollback
      )
    }
  }
}

private struct PreparedLocalPublishWrite {
  let file: PublishPackageFile
  let destinationURL: URL
  let sourceURL: URL?
  let expectedSourceState: LocalPublishSourceFileState?
}

private struct LocalPublishRollbackEntry {
  let destinationURL: URL
  let backupURL: URL?
  var appliedState: LocalPublishFileState?
  var didMutateDestination: Bool
}

struct LocalPublishWriteResult {
  let writtenPaths: [String]
  let appliedStatesByRepositoryPath: [String: LocalPublishFileState]
}

public enum LocalPublishFileState: Codable, Hashable, Sendable {
  case missing
  case fileDigest(Data)
}

private func localPublishSourceFileState(
  at url: URL,
  repositoryPath: String
) throws -> LocalPublishSourceFileState {
#if canImport(Darwin)
  return try withLocalPublishSourceDescriptor(
    at: url,
    repositoryPath: repositoryPath
  ) { descriptor in
    try readLocalPublishSource(
      descriptor: descriptor,
      repositoryPath: repositoryPath,
      destinationDescriptor: nil
    )
  }
#else
  let values = try url.resourceValues(forKeys: [
    .isRegularFileKey,
    .isSymbolicLinkKey,
    .fileSizeKey,
    .fileResourceIdentifierKey,
  ])
  guard values.isRegularFile == true, values.isSymbolicLink != true else {
    throw LocalPublishPreviewError.unsafeSource(repositoryPath)
  }
  let digest = try BoundedFileReader.sha256(
    at: url,
    maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
  )
  let identifier = UInt64(bitPattern: Int64(values.fileResourceIdentifier?.hashValue ?? 0))
  return LocalPublishSourceFileState(
    byteSize: Int64(values.fileSize ?? 0),
    sha256: digest,
    deviceIdentifier: 0,
    fileIdentifier: identifier
  )
#endif
}

#if canImport(Darwin)
private func withLocalPublishSourceDescriptor<Result>(
  at url: URL,
  repositoryPath: String,
  operation: (Int32) throws -> Result
) throws -> Result {
  let descriptor = url.path.withCString {
    Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  }
  guard descriptor >= 0 else {
    if errno == ENOENT {
      throw LocalPublishPreviewError.missingSource(repositoryPath)
    }
    throw LocalPublishPreviewError.unsafeSource(repositoryPath)
  }
  defer { Darwin.close(descriptor) }
  return try operation(descriptor)
}

private func readLocalPublishSource(
  descriptor: Int32,
  repositoryPath: String,
  destinationDescriptor: Int32?
) throws -> LocalPublishSourceFileState {
  var initialMetadata = stat()
  guard Darwin.fstat(descriptor, &initialMetadata) == 0,
        (initialMetadata.st_mode & S_IFMT) == S_IFREG,
        initialMetadata.st_size >= 0,
        initialMetadata.st_size <= off_t(WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount) else {
    throw LocalPublishPreviewError.unsafeSource(repositoryPath)
  }

  var digest = SHA256()
  var totalBytes: Int64 = 0
  var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
  while true {
    let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
    }
    if bytesRead == 0 {
      break
    }
    if bytesRead < 0 {
      if errno == EINTR { continue }
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }

    totalBytes += Int64(bytesRead)
    guard totalBytes <= Int64(WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount) else {
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }

    if let destinationDescriptor {
      try buffer.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var writtenByteCount = 0
        while writtenByteCount < bytesRead {
          let result = Darwin.write(
            destinationDescriptor,
            baseAddress.advanced(by: writtenByteCount),
            bytesRead - writtenByteCount
          )
          if result < 0 {
            if errno == EINTR { continue }
            throw LocalPublishPreviewError.unsafeSource(repositoryPath)
          }
          guard result > 0 else {
            throw LocalPublishPreviewError.unsafeSource(repositoryPath)
          }
          writtenByteCount += result
        }
      }
    }
    digest.update(data: Data(buffer.prefix(bytesRead)))
  }

  var finalMetadata = stat()
  guard Darwin.fstat(descriptor, &finalMetadata) == 0,
        totalBytes == Int64(initialMetadata.st_size),
        localPublishSourceMetadataIsUnchanged(initialMetadata, finalMetadata) else {
    throw LocalPublishPreviewError.unsafeSource(repositoryPath)
  }

  return LocalPublishSourceFileState(
    byteSize: totalBytes,
    sha256: Data(digest.finalize()),
    deviceIdentifier: UInt64(initialMetadata.st_dev),
    fileIdentifier: UInt64(initialMetadata.st_ino)
  )
}

private func localPublishSourceMetadataIsUnchanged(_ lhs: stat, _ rhs: stat) -> Bool {
  lhs.st_dev == rhs.st_dev
    && lhs.st_ino == rhs.st_ino
    && lhs.st_size == rhs.st_size
    && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
    && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
    && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
#endif

func localPublishFileState(at url: URL, fileManager: FileManager) throws -> LocalPublishFileState {
  var isDirectory: ObjCBool = false
  guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    return .missing
  }
  guard !isDirectory.boolValue else {
    throw LocalPublishPreviewError.unsafePath(url.path)
  }
  return .fileDigest(try BoundedFileReader.sha256(
    at: url,
    maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
  ))
}
