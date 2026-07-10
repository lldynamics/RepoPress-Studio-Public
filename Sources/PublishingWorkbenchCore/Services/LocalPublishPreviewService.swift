import Foundation

public enum PublishFileDiffStatus: String, Codable, Sendable {
  case added
  case modified
  case unchanged
  case missingSource
  case unsafePath

  public var displayName: String {
    switch self {
    case .added:
      return "新增"
    case .modified:
      return "修改"
    case .unchanged:
      return "未变化"
    case .missingSource:
      return "源文件缺失"
    case .unsafePath:
      return "路径不安全"
    }
  }
}

public struct PublishFileDiff: Identifiable, Codable, Hashable, Sendable {
  public var id: String { path }
  public var path: String
  public var kind: PublishFileKind
  public var status: PublishFileDiffStatus
  public var lineDiff: String?
  public var byteSize: Int64

  public init(
    path: String,
    kind: PublishFileKind,
    status: PublishFileDiffStatus,
    lineDiff: String? = nil,
    byteSize: Int64 = 0
  ) {
    self.path = path
    self.kind = kind
    self.status = status
    self.lineDiff = lineDiff
    self.byteSize = byteSize
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

public struct LocalPublishPreviewService {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func preview(package: PublishPackage, profile: SiteProfile) -> LocalPublishPreview {
    guard let preview = profile.withLocalRepositoryRootAccess({ rootURL in
      preview(package: package, rootURL: rootURL)
    }) else {
      return missingRepositoryPreview(package: package)
    }

    return preview
  }

  func preview(package: PublishPackage, rootURL: URL) -> LocalPublishPreview {
    var diffs: [PublishFileDiff] = []
    var issues: [PreflightIssue] = []

    for file in package.files {
      guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: file.repositoryPath) else {
        diffs.append(
          PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .unsafePath, byteSize: file.byteSize)
        )
        issues.append(.init(severity: .error, title: "发布路径不安全", message: file.repositoryPath, field: "repositoryPath"))
        continue
      }

      switch file.kind {
      case .markdown:
        let newContent = file.content ?? ""
        let existingContent = (try? String(contentsOf: destinationURL, encoding: .utf8)) ?? ""
        let exists = fileManager.fileExists(atPath: destinationURL.path)
        let status: PublishFileDiffStatus = exists
          ? (existingContent == newContent ? .unchanged : .modified)
          : .added
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: status,
            lineDiff: status == .unchanged ? nil : unifiedDiff(old: existingContent, new: newContent),
            byteSize: Int64(newContent.utf8.count)
          )
        )
      case .image:
        guard let sourceFilePath = file.sourceFilePath,
              fileManager.fileExists(atPath: sourceFilePath)
        else {
          diffs.append(
            PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .missingSource, byteSize: file.byteSize)
          )
          issues.append(.init(severity: .error, title: "图片源文件缺失", message: file.repositoryPath, field: "attachments"))
          continue
        }

        let exists = fileManager.fileExists(atPath: destinationURL.path)
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: exists ? .modified : .added,
            byteSize: file.byteSize
          )
        )
      }
    }

    return LocalPublishPreview(package: package, fileDiffs: diffs, issues: issues)
  }

  public func write(package: PublishPackage, profile: SiteProfile) throws -> [String] {
    guard let writtenPaths = try profile.withLocalRepositoryRootAccess({ rootURL in
      try write(package: package, rootURL: rootURL)
    }) else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    return writtenPaths
  }

  func write(package: PublishPackage, rootURL: URL) throws -> [String] {
    var writtenPaths: [String] = []
    for file in package.files {
      let destinationURL = try safeDestinationURLForWrite(
        rootURL: rootURL,
        repositoryPath: file.repositoryPath
      )

      switch file.kind {
      case .markdown:
        try (file.content ?? "").write(to: destinationURL, atomically: true, encoding: .utf8)
      case .image:
        guard let sourceFilePath = file.sourceFilePath else {
          throw LocalPublishPreviewError.missingSource(file.repositoryPath)
        }
        let sourceURL = URL(fileURLWithPath: sourceFilePath)
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
      }

      writtenPaths.append(file.repositoryPath)
    }
    return writtenPaths
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

  private func missingRepositoryPreview(package: PublishPackage) -> LocalPublishPreview {
    LocalPublishPreview(
      package: package,
      fileDiffs: package.files.map {
        PublishFileDiff(path: $0.repositoryPath, kind: $0.kind, status: .unsafePath, byteSize: $0.byteSize)
      },
      issues: [
        .init(severity: .warning, title: "未选择本地仓库", message: "选择仓库后才能生成真实文件 diff。", field: "repository")
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

  private func isSymbolicLink(_ url: URL) -> Bool {
    // destinationOfSymbolicLink catches dangling links too, unlike fileExists.
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func unifiedDiff(old: String, new: String) -> String {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lines: [String] = ["--- repository", "+++ publish-package"]
    let maxCount = max(oldLines.count, newLines.count)

    for index in 0..<maxCount {
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

    return lines.joined(separator: "\n")
  }
}

public enum LocalPublishPreviewError: LocalizedError {
  case missingRepositoryRoot
  case unsafePath(String)
  case missingSource(String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      return "未选择本地仓库。"
    case .unsafePath(let path):
      return "发布路径不安全：\(path)"
    case .missingSource(let path):
      return "源文件缺失：\(path)"
    }
  }
}
