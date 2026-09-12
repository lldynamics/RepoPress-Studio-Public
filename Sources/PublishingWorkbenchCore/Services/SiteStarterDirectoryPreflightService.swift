import Foundation

/// Read-only facts about a local directory before it is imported or used as a
/// Starter target. Write-time checks in `SiteStarterService` remain authoritative.
public struct SiteStarterDirectoryPreflight: Hashable, Sendable {
  public var rootPath: String
  public var exists: Bool
  public var isDirectory: Bool
  public var isReadable: Bool
  public var isWritable: Bool
  public var parentIsDirectory: Bool
  public var parentIsWritable: Bool
  public var visibleEntryCount: Int?
  public var markdownFileCount: Int?
  public var selectedContentRootPath: String
  public var detectedContentRootPath: String?
  public var isGitRepository: Bool
  public var detectedSiteKind: SiteKind?
  public var detectionEvidence: [String]
  public var detectionIsAmbiguous: Bool
  public var traversalWasCapped: Bool
  public var readErrorMessage: String?

  public init(
    rootPath: String,
    exists: Bool,
    isDirectory: Bool,
    isReadable: Bool,
    isWritable: Bool,
    parentIsDirectory: Bool,
    parentIsWritable: Bool,
    visibleEntryCount: Int?,
    markdownFileCount: Int?,
    selectedContentRootPath: String,
    detectedContentRootPath: String?,
    isGitRepository: Bool,
    detectedSiteKind: SiteKind?,
    detectionEvidence: [String],
    detectionIsAmbiguous: Bool,
    traversalWasCapped: Bool,
    readErrorMessage: String?
  ) {
    self.rootPath = rootPath
    self.exists = exists
    self.isDirectory = isDirectory
    self.isReadable = isReadable
    self.isWritable = isWritable
    self.parentIsDirectory = parentIsDirectory
    self.parentIsWritable = parentIsWritable
    self.visibleEntryCount = visibleEntryCount
    self.markdownFileCount = markdownFileCount
    self.selectedContentRootPath = selectedContentRootPath
    self.detectedContentRootPath = detectedContentRootPath
    self.isGitRepository = isGitRepository
    self.detectedSiteKind = detectedSiteKind
    self.detectionEvidence = detectionEvidence
    self.detectionIsAmbiguous = detectionIsAmbiguous
    self.traversalWasCapped = traversalWasCapped
    self.readErrorMessage = readErrorMessage
  }
}

/// Performs bounded local filesystem inspection. It never invokes Git, reads
/// credentials, writes a site, or validates remote access.
public struct SiteStarterDirectoryPreflightService: Sendable {
  public static let maximumTraversalEntries = 2_048
  private let fileSystem: SendableFileManager

  public init(fileManager: FileManager = .default) {
    fileSystem = SendableFileManager(fileManager)
  }

  public func inspect(
    path: String,
    selectedSiteKind: SiteKind,
    cancellationCheck: @escaping @Sendable () -> Bool = { false }
  ) -> SiteStarterDirectoryPreflight? {
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else { return nil }

    let rootURL = URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
    let selectedContentRoot = SiteProfile.defaultPublishingDefaults(for: selectedSiteKind)
      .contentRoot.normalizedRelativePath()
    let parentURL = rootURL.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    let exists = fileSystem.value.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
    let parentIsDirectory = directoryExists(parentURL)
    let parentIsWritable = parentIsDirectory && fileSystem.value.isWritableFile(atPath: parentURL.path)

    guard exists, isDirectory.boolValue else {
      return SiteStarterDirectoryPreflight(
        rootPath: rootURL.path,
        exists: exists,
        isDirectory: isDirectory.boolValue,
        isReadable: false,
        isWritable: false,
        parentIsDirectory: parentIsDirectory,
        parentIsWritable: parentIsWritable,
        visibleEntryCount: nil,
        markdownFileCount: nil,
        selectedContentRootPath: selectedContentRoot,
        detectedContentRootPath: nil,
        isGitRepository: false,
        detectedSiteKind: nil,
        detectionEvidence: [],
        detectionIsAmbiguous: false,
        traversalWasCapped: false,
        readErrorMessage: exists ? CoreL10n.text("所选路径不是目录。") : nil
      )
    }

    do {
      let children = try fileSystem.value.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: []
      )
      let fallbackProfile = SiteProfile(name: "预检", siteKind: selectedSiteKind)
      let proposal = LocalRepositoryService().autoConfigurationProposal(
        for: rootURL,
        fallbackProfile: fallbackProfile
      )
      let ambiguous = hasAmbiguousConfiguration(at: rootURL, proposal: proposal)
      let traversal = markdownTraversal(
        at: rootURL.appendingPathComponent(selectedContentRoot, isDirectory: true),
        cancellationCheck: cancellationCheck
      )
      return SiteStarterDirectoryPreflight(
        rootPath: rootURL.path,
        exists: true,
        isDirectory: true,
        // Successfully listing the root is the meaningful read capability for
        // this preflight; `isReadableFile` is unreliable for directories on
        // some volume providers.
        isReadable: true,
        isWritable: fileSystem.value.isWritableFile(atPath: rootURL.path),
        parentIsDirectory: parentIsDirectory,
        parentIsWritable: parentIsWritable,
        visibleEntryCount: children.filter { $0.lastPathComponent != ".DS_Store" }.count,
        markdownFileCount: traversal.count,
        selectedContentRootPath: selectedContentRoot,
        detectedContentRootPath: ambiguous ? nil : proposal.detectedKind.map { _ in proposal.contentRoot },
        isGitRepository: proposal.isGitRepository,
        detectedSiteKind: ambiguous ? nil : proposal.detectedKind,
        detectionEvidence: ambiguous ? ambiguousEvidence(at: rootURL) : proposal.evidence,
        detectionIsAmbiguous: ambiguous,
        traversalWasCapped: traversal.wasCapped,
        readErrorMessage: traversal.errorMessage
      )
    } catch {
      return SiteStarterDirectoryPreflight(
        rootPath: rootURL.path,
        exists: true,
        isDirectory: true,
        isReadable: false,
        isWritable: fileSystem.value.isWritableFile(atPath: rootURL.path),
        parentIsDirectory: parentIsDirectory,
        parentIsWritable: parentIsWritable,
        visibleEntryCount: nil,
        markdownFileCount: nil,
        selectedContentRootPath: selectedContentRoot,
        detectedContentRootPath: nil,
        isGitRepository: false,
        detectedSiteKind: nil,
        detectionEvidence: [],
        detectionIsAmbiguous: false,
        traversalWasCapped: false,
        readErrorMessage: error.localizedDescription
      )
    }
  }

  public func inspectAsync(
    path: String,
    selectedSiteKind: SiteKind
  ) async -> SiteStarterDirectoryPreflight? {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      service.inspect(path: path, selectedSiteKind: selectedSiteKind, cancellationCheck: { Task.isCancelled })
    }
    return await withTaskCancellationHandler(
      operation: { await task.value },
      onCancel: { task.cancel() }
    )
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileSystem.value.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func hasAmbiguousConfiguration(
    at rootURL: URL,
    proposal: RepositoryAutoConfigurationProposal
  ) -> Bool {
    if fileSystem.value.fileExists(atPath: rootURL.appendingPathComponent("_config.yml").path),
      !directoryExists(rootURL.appendingPathComponent("source/_posts", isDirectory: true)),
      !fileSystem.value.fileExists(atPath: rootURL.appendingPathComponent("package.json").path)
    {
      return true
    }
    return proposal.detectedKind == nil
      && fileSystem.value.fileExists(atPath: rootURL.appendingPathComponent("config.toml").path)
  }

  private func ambiguousEvidence(at rootURL: URL) -> [String] {
    if fileSystem.value.fileExists(atPath: rootURL.appendingPathComponent("_config.yml").path) {
      return [CoreL10n.text("_config.yml（无法仅凭此区分 Hexo 与 Jekyll）")]
    }
    return [CoreL10n.text("config.toml（缺少可识别的 Zola/Hugo 标记）")]
  }

  private func markdownTraversal(
    at contentRootURL: URL,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> (count: Int?, wasCapped: Bool, errorMessage: String?) {
    guard directoryExists(contentRootURL) else { return (0, false, nil) }
    var pendingDirectories = [contentRootURL]
    var visitedEntries = 0
    var markdownCount = 0
    let excludedNames: Set<String> = [".git", "node_modules", "public", "dist", ".build"]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    while let directoryURL = pendingDirectories.popLast() {
      if cancellationCheck() { return (nil, false, CoreL10n.text("目录预检已取消。")) }
      let children: [URL]
      do {
        children = try fileSystem.value.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles]
        )
      } catch {
        return (nil, false, error.localizedDescription)
      }
      for childURL in children.sorted(by: { $0.path < $1.path }) {
        if cancellationCheck() { return (nil, false, CoreL10n.text("目录预检已取消。")) }
        guard visitedEntries < Self.maximumTraversalEntries else { return (markdownCount, true, nil) }
        visitedEntries += 1
        guard !excludedNames.contains(childURL.lastPathComponent),
          let values = try? childURL.resourceValues(forKeys: keys),
          values.isSymbolicLink != true
        else { continue }
        if values.isDirectory == true {
          pendingDirectories.append(childURL)
        } else if values.isRegularFile == true,
          ["md", "markdown", "mdx"].contains(childURL.pathExtension.lowercased())
        {
          markdownCount += 1
        }
      }
    }
    return (markdownCount, false, nil)
  }
}
