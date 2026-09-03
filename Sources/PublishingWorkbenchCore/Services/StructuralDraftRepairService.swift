import CryptoKit
import Foundation

/// Read-only Git inspection and a narrowly scoped, preview-bound local repair.
/// This service never stages, commits, changes branches, or contacts a remote.
struct StructuralDraftRepairService: Sendable {
  private let files = LocalPublishPreviewService()
  private let git = GitCommandRunner(timeout: 15, maximumOutputBytes: 1_048_576)

  func preview(profile: SiteProfile, drafts: [ArticleDraft]) -> StructuralDraftRepairPreview {
    let candidates = drafts.compactMap { draft -> StructuralDraftRepairItem? in
      guard draft.belongs(toSiteProfileID: profile.id),
        let path = StructuralArticlePathPolicy.protectedPath(for: draft, profile: profile)
      else { return nil }
      return .init(id: draft.id, title: draft.title, repositoryPath: path)
    }
    var warnings: [String] = []
    var sourceCommit: String?
    var filePreview: LocalPublishPreview?
    var restorations: [StructuralFileRepairItem] = []
    if profile.siteKind == .zola || profile.siteKind == .hugo {
      do {
        guard let root = profile.localRepositoryRootURL else {
          throw StructuralDraftRepairError.unavailable("未选择本地仓库，只能修复工作台记录。")
        }
        try validateRoot(root)
        try requireNoPendingTransaction(root)
        let commit = try runGit(["rev-parse", "HEAD"], root: root).trimmedForPublishing
        let listing = try runGit(["ls-tree", "-r", "-z", "--full-tree", commit], root: root)
        var objectIDs: [String: String] = [:]
        let paths: [String] = listing.split(separator: "\0").compactMap { record -> String? in
          let parts = record.split(separator: "\t", maxSplits: 1)
          guard parts.count == 2,
            parts[0].hasPrefix("100644 blob ")
              || parts[0].hasPrefix("100755 blob ")
          else { return nil }
          let path = String(parts[1])
          let contentRoot = profile.contentRoot.normalizedRelativePath()
          guard files.destinationURL(rootURL: root, repositoryPath: path) != nil,
            !files.isGitControlPath(path),
            contentRoot.isEmpty || path.hasPrefix(contentRoot + "/"),
            StructuralArticlePathPolicy.isProtected(path, profile: profile)
          else { return nil }
          objectIDs[path] = String(parts[0].split(separator: " ").last ?? "")
          return path
        }
        guard paths.count <= 256 else {
          throw StructuralDraftRepairError.unavailable("结构文件超过 256 个，请先缩小内容目录范围。")
        }
        let packageFiles: [PublishPackageFile] = try paths.map { path in
          PublishPackageFile(
            kind: .markdown, repositoryPath: path,
            content: try readBlob(objectID: objectIDs[path] ?? "", root: root)
          )
        }
        let package = PublishPackage(
          draftID: UUID(), title: "栏目文件恢复预览", markdownPath: paths.first ?? "",
          files: packageFiles, commitMessage: "", reviewBranchName: "",
          reviewTitle: "", reviewChecklist: []
        )
        let inspected = files.preview(package: package, rootURL: root)
        warnings.append(contentsOf: inspected.issues.map(\.message))
        let safeDiffs = inspected.fileDiffs.filter {
          ($0.status == .added || $0.status == .modified) && $0.baselineState != nil
        }
        let safePaths = Set(safeDiffs.map(\.path))
        var safePreview = inspected
        safePreview.package.files = packageFiles.filter { safePaths.contains($0.repositoryPath) }
        safePreview.fileDiffs = safeDiffs
        safePreview.issues = []
        filePreview = safePreview
        sourceCommit = commit
        restorations = safeDiffs.map {
          .init(repositoryPath: $0.path, diff: $0.lineDiff ?? "", wasMissing: $0.status == .added)
        }
      } catch {
        warnings.append(error.localizedDescription)
      }
    }
    return .init(
      id: UUID(), profileID: profile.id, profileName: profile.name,
      drafts: candidates, files: restorations, sourceCommit: sourceCommit, warnings: warnings,
      profileSnapshot: profile, draftSnapshots: drafts, filePreview: filePreview
    )
  }

  func validateFiles(_ preview: StructuralDraftRepairPreview, paths: Set<String>) throws {
    guard !paths.isEmpty else { return }
    guard let root = preview.profileSnapshot.localRepositoryRootURL,
      let commit = preview.sourceCommit, let filePreview = preview.filePreview,
      paths.isSubset(of: Set(preview.files.map(\.repositoryPath)))
    else { throw StructuralDraftRepairError.invalidSelection }
    try validateRoot(root)
    try requireNoPendingTransaction(root)
    guard try runGit(["rev-parse", "HEAD"], root: root).trimmedForPublishing == commit else {
      throw StructuralDraftRepairError.stalePreview
    }
    for diff in filePreview.fileDiffs where paths.contains(diff.path) {
      let destination = try files.validatedDestinationURLForWrite(
        rootURL: root, repositoryPath: diff.path)
      guard try localPublishFileState(at: destination, fileManager: .default) == diff.baselineState
      else {
        throw StructuralDraftRepairError.stalePreview
      }
    }
  }

  func createBackup(
    snapshot: WorkbenchSnapshot, preview: StructuralDraftRepairPreview,
    selectedDraftIDs: Set<UUID>, paths: Set<String>, parentURL: URL
  ) throws -> URL {
    try validateFiles(preview, paths: paths)
    let fm = FileManager.default
    guard !files.isSymbolicLink(parentURL) else {
      throw StructuralDraftRepairError.unavailable("修复备份目录不能是符号链接，未执行修复。")
    }
    let destination = parentURL.appendingPathComponent(
      "structural-repair-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(
      at: destination, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let snapshotData = try JSONEncoder.workbench.encode(snapshot)
    try writeBackup(snapshotData, to: destination.appendingPathComponent("workbench-before.json"))
    // Verify the backup is readable before any in-memory or repository mutation.
    _ = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: Data(contentsOf: destination.appendingPathComponent("workbench-before.json")))
    var originals: [String: String] = [:]
    if let root = preview.profileSnapshot.localRepositoryRootURL {
      for (index, path) in paths.sorted().enumerated() {
        let target = try files.validatedDestinationURLForWrite(rootURL: root, repositoryPath: path)
        if fm.fileExists(atPath: target.path) {
          let name = "original-\(index).md"
          let data = try BoundedFileReader.data(at: target, maximumByteCount: 1_048_576)
          try writeBackup(data, to: destination.appendingPathComponent(name))
          originals[path] = name
        } else {
          originals[path] = "(originally missing)"
        }
      }
    }
    let manifest: [String: Any] = [
      "profileID": preview.profileID.uuidString,
      "sourceCommit": preview.sourceCommit ?? "",
      "draftIDs": selectedDraftIDs.map(\.uuidString).sorted(),
      "originalFiles": originals,
      "scope":
        "Workspace snapshot and selected local section files only; no Git or remote mutation.",
    ]
    try writeBackup(
      try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
      to: destination.appendingPathComponent("manifest.json"))
    try validateFiles(preview, paths: paths)
    return destination
  }

  func restoreFiles(_ preview: StructuralDraftRepairPreview, paths: Set<String>) throws -> [String]
  {
    guard !paths.isEmpty else { return [] }
    try validateFiles(preview, paths: paths)
    guard var selected = preview.filePreview,
      let root = preview.profileSnapshot.localRepositoryRootURL
    else {
      throw StructuralDraftRepairError.invalidSelection
    }
    selected.package.files = selected.package.files.filter { paths.contains($0.repositoryPath) }
    selected.fileDiffs = selected.fileDiffs.filter { paths.contains($0.path) }
    // Only this dedicated confirmation flow may restore section files. It uses
    // the existing CAS/rollback transaction engine, not the article write API.
    return try files.write(preview: selected, rootURL: root, purpose: .structuralRepair(paths))
  }

  private func writeBackup(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func validateRoot(_ root: URL) throws {
    let actual = try runGit(["rev-parse", "--show-toplevel"], root: root).trimmedForPublishing
    guard
      URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL
        == root.resolvingSymlinksInPath().standardizedFileURL
    else {
      throw StructuralDraftRepairError.unavailable("修复目录不是 Git 仓库根目录，未修改任何文件。")
    }
  }

  private func requireNoPendingTransaction(_ root: URL) throws {
    let url = root.appendingPathComponent(LocalPublishPreviewService.transactionFileName)
    guard !FileManager.default.fileExists(atPath: url.path), !files.isSymbolicLink(url) else {
      throw StructuralDraftRepairError.unavailable("仓库有未完成的写入事务；本次只允许修复工作台记录，栏目文件需先检查原事务。")
    }
  }

  private func runGit(_ arguments: [String], root: URL) throws -> String {
    let result = git.run(arguments, rootURL: root)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw StructuralDraftRepairError.unavailable("无法完整读取本地 Git 基线：\(result.output)")
    }
    return result.standardOutput
  }

  private func readBlob(objectID: String, root: URL) throws -> String {
    // GitCommandRunner trims the outer command output. A batch terminator
    // preserves the blob's leading/trailing whitespace inside the response.
    let result = git.run(
      ["cat-file", "--batch"], rootURL: root,
      inputLines: [objectID, String(repeating: "0", count: objectID.count)])
    let bytes = Data(result.standardOutput.utf8)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated,
      let newline = bytes.firstIndex(of: 10),
      let header = String(data: bytes[..<newline], encoding: .utf8)
    else {
      throw StructuralDraftRepairError.unavailable("无法完整读取栏目文件的 Git 对象。")
    }
    let fields = header.split(separator: " ")
    guard fields.count == 3, fields[0] == objectID, fields[1] == "blob",
      let size = Int(fields[2]), size >= 0, size <= 524_288,
      bytes.count > newline + 1 + size
    else {
      throw StructuralDraftRepairError.unavailable("栏目 Git 对象不完整或超过 512 KiB，未提供自动恢复。")
    }
    let content = Data(bytes[(newline + 1)..<(newline + 1 + size)])
    var object = Data("blob \(size)\0".utf8)
    object.append(content)
    let digest =
      objectID.count == 64
      ? SHA256.hash(data: object).map { String(format: "%02x", $0) }.joined()
      : Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
    guard digest == objectID, let text = String(data: content, encoding: .utf8) else {
      throw StructuralDraftRepairError.unavailable("栏目 Git 对象校验失败或不是 UTF-8，未提供自动恢复。")
    }
    return text
  }
}
