import Foundation

struct ProjectFileConflictRootIdentity: Equatable, Sendable {
  let canonicalPath: String
  let device: UInt64
  let inode: UInt64
  let gitDevice: UInt64
  let gitInode: UInt64

  init(root: URL) throws {
    canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let gitAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(".git").path)
    guard let device = rootAttributes[.systemNumber] as? NSNumber,
      let inode = rootAttributes[.systemFileNumber] as? NSNumber,
      let gitDevice = gitAttributes[.systemNumber] as? NSNumber,
      let gitInode = gitAttributes[.systemFileNumber] as? NSNumber else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("无法确认项目目录身份，请重新选择目录。"))
    }
    self.device = device.uint64Value
    self.inode = inode.uint64Value
    self.gitDevice = gitDevice.uint64Value
    self.gitInode = gitInode.uint64Value
  }
}

struct ProjectFileConflictService: Sendable {
  func review(draft: ArticleDraft, profile: SiteProfile) throws -> ProjectFileConflictReview {
    guard !draft.isGeneralDraft, let root = profile.localRepositoryRootURL,
      let path = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty
    else { throw ProjectSaveRecoveryError.message(CoreL10n.text("草稿未绑定项目文件。")) }
    try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: root)
    let rootIdentity = try ProjectFileConflictRootIdentity(root: root)
    let document = try BoundedFileReader.utf8String(
      relativePath: path, under: root, maximumByteCount: 16 * 1_024 * 1_024)
    let diskDraft = try LocalContentImportService().parseProjectDocument(
      document, repositoryPath: path, rootURL: root, profile: profile)
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    guard let local = package.files.first(where: {
      $0.kind == .markdown && $0.operation == .upsert && $0.repositoryPath == path
    })?.content else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("草稿路径已变化，请重新检查项目文件。"))
    }
    guard try ProjectFileConflictRootIdentity(root: root) == rootIdentity else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("项目目录已被替换，请重新载入差异。"))
    }
    return ProjectFileConflictReview(
      rootIdentity: rootIdentity, draft: draft, profile: profile, repositoryPath: path,
      rootPath: root.standardizedFileURL.path, draftDocument: local,
      diskDocument: document, diskContentDigest: ArticleDraft.repositoryDocumentDigest(document),
      diskDraft: diskDraft)
  }

  func validateRoot(_ review: ProjectFileConflictReview) throws {
    guard let root = review.profile.localRepositoryRootURL,
      try ProjectFileConflictRootIdentity(root: root) == review.rootIdentity else {
      throw ProjectSaveRecoveryError.message(CoreL10n.text("项目目录已被替换，请重新载入差异。"))
    }
  }

  func mergePreview(document: String, review: ProjectFileConflictReview) throws -> LocalPublishPreview {
    try validateRoot(review)
    var package = PublishPackageBuilder().build(draft: review.draft, profile: review.profile)
    package.markdownPath = review.repositoryPath
    package.files = [PublishPackageFile(kind: .markdown, repositoryPath: review.repositoryPath, content: document)]
    let preview = LocalPublishPreviewService().preview(package: package, profile: review.profile)
    guard preview.fileDiffs.count == 1,
      case .fileDigest(let digest) = preview.fileDiffs.first?.baselineState,
      digest.map({ String(format: "%02x", $0) }).joined() == review.diskContentDigest
    else { throw SiteDraftFileStoreError.projectFileChangedExternally(review.repositoryPath) }
    return preview
  }

  /// Preserve the exact source bytes as well as the complete original model;
  /// the Markdown importer may normalize formatting and unknown front matter.
  func archive(_ review: ProjectFileConflictReview, under dataRoot: URL) throws {
    let root = dataRoot.appendingPathComponent("RecoveryArchives/ProjectFileConflicts", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = [
      "draft.json": try JSONEncoder.workbench.encode(review.draft),
      "draft.md": Data(review.draftDocument.utf8),
      "project.md": Data(review.diskDocument.utf8),
    ]
    for (name, data) in files {
      let file = root.appendingPathComponent(name)
      try data.write(to: file, options: [.atomic])
      guard try Data(contentsOf: file) == data else {
        throw ProjectSaveRecoveryError.message(CoreL10n.text("冲突恢复副本校验失败，原内容保持不变。"))
      }
    }
  }
}
