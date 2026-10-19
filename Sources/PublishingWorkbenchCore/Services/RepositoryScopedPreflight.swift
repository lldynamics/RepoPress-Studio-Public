import Foundation
import PublishingCoreSupport
import PublishingGitCore

/// Builds the tree a single-article commit would publish, without borrowing
/// unrelated edits or touching the real index. Shared committed dependencies
/// still participate in the build; only uncommitted changes outside scope are excluded.
enum RepositoryScopedPreflight {
  static func validatedResult(
    profile: SiteProfile, snapshot: RepositoryWorktreePublishSnapshot, pathScope: [String]?,
    git: GitCommandRunner, service: RepositoryPublishPreflightService
  ) throws -> RepositoryPublishPreflightResult {
    let result =
      try pathScope == nil
      ? service.run(profile: profile)
      : run(profile: profile, snapshot: snapshot, git: git, service: service)
    guard !result.blocksPublication else {
      throw RepositoryWorktreePublishError.sitePreflightFailed(result.message)
    }
    return result
  }

  static func run(
    profile: SiteProfile, snapshot: RepositoryWorktreePublishSnapshot,
    git: GitCommandRunner, service: RepositoryPublishPreflightService
  ) throws -> RepositoryPublishPreflightResult {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
    let temporary = manager.temporaryDirectory.appendingPathComponent(
      "RepoPress-Scoped-Preflight-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(
      at: temporary, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer {
      do { try manager.removeItem(at: temporary) } catch {
        // Best-effort private build cleanup.
      }
    }
    let source = temporary.appendingPathComponent("source", isDirectory: true)
    let index = temporary.appendingPathComponent("index")
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    func command(_ args: [String]) throws -> String {
      let result = git.run(
        args, rootURL: root, preserveStandardOutputWhitespace: true,
        environmentOverrides: ["GIT_INDEX_FILE": index.path])
      guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
        throw RepositoryWorktreePublishError.sitePreflightFailed(result.output)
      }
      return result.standardOutput
    }
    _ = try command(["read-tree", snapshot.headSHA])
    let entries = try command(["ls-files", "--stage", "-z"])
    for record in entries.split(separator: "\0") {
      guard let tab = record.firstIndex(of: "\t"),
        let mode = record.split(separator: " ").first,
        mode == "100644" || mode == "100755"
      else {
        throw RepositoryWorktreePublishError.invalidRepository(
          "单篇构建快照不能包含符号链接或未展开的子模块。")
      }
      try validate(String(record[record.index(after: tab)...]))
    }
    _ = try command(["checkout-index", "--all", "--prefix=\(source.path)/"])
    for entry in snapshot.entries {
      try validate(entry.path)
      if entry.kind == .renamed, let oldPath = entry.sourcePath, oldPath != entry.path {
        try validate(oldPath)
        let old = source.appendingPathComponent(oldPath)
        if manager.fileExists(atPath: old.path) { try manager.removeItem(at: old) }
      }
      let target = source.appendingPathComponent(entry.path)
      if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
      if entry.kind == .deleted { continue }
      guard entry.mode == "100644" || entry.mode == "100755" else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }
      let data = try BoundedFileReader.data(
        relativePath: entry.path, under: root, maximumByteCount: 256 * 1_024 * 1_024)
      guard Int64(data.count) == entry.byteSize else {
        throw RepositoryWorktreePublishError.snapshotDrift
      }
      try manager.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
      let oid = try command(["hash-object", "--no-filters", "--", target.path])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard oid == entry.blobOID else { throw RepositoryWorktreePublishError.snapshotDrift }
      try manager.setAttributes(
        [.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644],
        ofItemAtPath: target.path)
    }
    // Installed runtime dependencies are not publication content. Preserve
    // them for Node generators; the engine's existing staged-link check still
    // rejects dependencies escaping the build copy.
    if [.astro, .vitePress, .hexo, .quartz, .docusaurus].contains(profile.siteKind) {
      let dependencies = root.appendingPathComponent("node_modules", isDirectory: true)
      let destination = source.appendingPathComponent("node_modules", isDirectory: true)
      if manager.fileExists(atPath: dependencies.path),
        !manager.fileExists(atPath: destination.path)
      {
        try manager.copyItem(at: dependencies, to: destination)
      }
    }
    var stagedProfile = profile
    stagedProfile.localRepositoryRootPath = source.path
    return service.run(profile: stagedProfile)
  }

  private static func validate(_ path: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty,
      !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }
      ),
      !path.contains("\\"), !path.contains(":")
    else { throw RepositoryWorktreePublishError.snapshotDrift }
  }
}
