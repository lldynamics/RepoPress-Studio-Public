import XCTest

@testable import PublishingWorkbenchCore

final class StructuralArticleProtectionTests: XCTestCase {
  func testOnlySectionNamesForSectionBasedGeneratorsAreProtected() {
    var profile = SiteProfile.defaultProfile
    for kind in [SiteKind.zola, .hugo] {
      profile.siteKind = kind
      XCTAssertTrue(
        StructuralArticlePathPolicy.isProtected("content/2026/_INDEX.MD", profile: profile))
      XCTAssertFalse(
        StructuralArticlePathPolicy.isProtected("content/post/index.md", profile: profile))
      XCTAssertFalse(
        StructuralArticlePathPolicy.isProtected("content/post/_index-guide.md", profile: profile))
    }
    profile.siteKind = .jekyll
    XCTAssertFalse(StructuralArticlePathPolicy.isProtected("_posts/_index.md", profile: profile))
  }

  func testLocalWriteAndAutosaveCannotRewriteOrMoveLegacySection() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = root.path
    profile.markdownPathPattern = "content/{slug}.md"
    let path = "content/_index.md"
    let target = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "original section".write(to: target, atomically: true, encoding: .utf8)
    let draft = ArticleDraft(
      siteProfileID: profile.id, title: "legacy", slug: "new-article",
      bodyMarkdown: "must not overwrite", repositoryPath: path)
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    XCTAssertTrue(package.files.contains { $0.operation == .delete && $0.repositoryPath == path })
    let writer = LocalPublishPreviewService()
    XCTAssertTrue(
      writer.preview(package: package, profile: profile).issues.contains {
        $0.title.contains("栏目结构页") && $0.severity == .error
      })
    XCTAssertThrowsError(try writer.write(package: package, profile: profile))
    do {
      _ = try await writer.writeAsync(package: package, profile: profile)
      XCTFail("Expected structural rejection")
    } catch is StructuralArticlePathError {}
    XCTAssertThrowsError(try SiteDraftFileStore().write(draft: draft, profile: profile))
    XCTAssertThrowsError(
      try LocalGitPublishService().publish(package: package, profile: profile, mode: .reviewBranch))
    do {
      _ = try await LocalGitPublishService().publishAsync(
        package: package, profile: profile, mode: .reviewBranch)
      XCTFail("Expected rejection before Git")
    } catch is StructuralArticlePathError {}
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original section")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("content/new-article.md").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(LocalPublishPreviewService.transactionFileName).path))
  }

  func testRemotePreflightAndPublishRejectBeforeAnyRequestForBothProviders() async throws {
    for provider in [RepositoryProvider.github, .gitlab] {
      var profile = SiteProfile.defaultProfile
      profile.siteKind = .zola
      profile.repositoryProvider = provider
      profile.markdownPathPattern = "content/{slug}.md"
      let draft = ArticleDraft(siteProfileID: profile.id, title: "section", slug: "_index")
      let package = PublishPackageBuilder().build(draft: draft, profile: profile)
      let transport = SequencedRemoteRepositoryTransport(responses: [])
      let service = RemoteRepositoryPublishService(transport: transport)
      do {
        _ = try await service.preflight(package: package, profile: profile, token: "test-token")
        XCTFail("Expected preflight rejection")
      } catch is StructuralArticlePathError {}
      for mode in [RemoteRepositoryPublishMode.directCommit, .reviewRequest, .previewBranch] {
        do {
          _ = try await service.publish(
            package: package, profile: profile, mode: mode, token: "test-token")
          XCTFail("Expected publish rejection")
        } catch is StructuralArticlePathError {}
      }
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testLegacySectionTransactionIsNotReplayedByNormalArticleWrite() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.localRepositoryRootPath = root.path
    profile.markdownPathPattern = "content/{slug}.md"
    let transaction = LocalPublishTransaction(
      phase: .applying,
      rollbackDirectoryPath: root.appendingPathComponent(".repopress-local-publish-rollback-old")
        .path,
      entries: [.init(repositoryPath: "content/_index.md", backupFileName: nil)])
    let journal = root.appendingPathComponent(LocalPublishPreviewService.transactionFileName)
    let encoded = try JSONEncoder().encode(transaction)
    try encoded.write(to: journal)
    let draft = ArticleDraft(siteProfileID: profile.id, title: "safe article", slug: "safe")
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    XCTAssertThrowsError(try LocalPublishPreviewService().write(package: package, profile: profile))
    { error in
      XCTAssertTrue(error is StructuralArticlePathError)
    }
    XCTAssertEqual(try Data(contentsOf: journal), encoded)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path),
      [LocalPublishPreviewService.transactionFileName])
  }

  func testFailedRepairRollsBackOnlyItsOwnWritesAndPreservesExternalEdit() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = ["content/first/_index.md", "content/second/_index.md"]
    for path in paths {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "original".write(to: url, atomically: true, encoding: .utf8)
    }
    let first = root.appendingPathComponent(paths[0])
    let second = root.appendingPathComponent(paths[1])
    let fileManager = ExternalEditDuringBackupFileManager(target: second)
    let service = LocalPublishPreviewService(fileManager: fileManager)
    let package = PublishPackage(
      draftID: UUID(), title: "Repair", markdownPath: paths[0],
      files: paths.map { .init(kind: .markdown, repositoryPath: $0, content: "restored section") },
      commitMessage: "", reviewBranchName: "", reviewTitle: "", reviewChecklist: [])
    let preview = service.preview(package: package, rootURL: root)

    XCTAssertThrowsError(
      try service.write(
        preview: preview, rootURL: root,
        purpose: .structuralRepair(Set(paths)))
    ) { error in
      guard case .previewOutdated(paths[1])? = error as? LocalPublishPreviewError else {
        return XCTFail("Expected external edit to invalidate preview, got \(error)")
      }
    }

    XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "original")
    XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "external editor content")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          root.appendingPathComponent(LocalPublishPreviewService.transactionFileName).path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path)
        .contains { $0.hasPrefix(".repopress-local-publish-rollback-") })
  }

  func testRollbackRefusesToOverwriteAnAppliedFileThatChangedExternally() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("_index.md")
    let backup = root.appendingPathComponent("backup")
    try "original section".write(to: backup, atomically: true, encoding: .utf8)
    try "restored section".write(to: target, atomically: true, encoding: .utf8)
    let applied = try localPublishFileState(at: target, fileManager: .default)
    try "external editor content".write(to: target, atomically: true, encoding: .utf8)
    let entries = [
      LocalPublishRollbackEntry(
        destinationURL: target, backupURL: backup,
        appliedState: applied, didMutateDestination: true)
    ]

    XCTAssertThrowsError(try LocalPublishPreviewService().rollbackLocalPublishWrites(entries))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external editor content")
    XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "original section")
  }

  func testExternalEditImmediatelyAfterWriteIsNeverAdoptedAsOurPayload() throws {
    for isStructuralRepair in [true, false] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let name = isStructuralRepair ? "_index.md" : "article.md"
      let paths = ["content/first/\(name)", "content/second/\(name)"]
      let targets = paths.map { root.appendingPathComponent($0) }
      for target in targets {
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original".write(to: target, atomically: true, encoding: .utf8)
      }
      let manager = ExternalEditAfterWriteFileManager(targets: targets)
      let service = LocalPublishPreviewService(fileManager: manager)
      let package = PublishPackage(
        draftID: UUID(), title: "Repair", markdownPath: paths[0],
        files: paths.map {
          .init(kind: .markdown, repositoryPath: $0, content: "intended payload")
        },
        commitMessage: "", reviewBranchName: "", reviewTitle: "", reviewChecklist: [])
      let preview = service.preview(package: package, rootURL: root)
      let purpose: LocalPublishWritePurpose =
        isStructuralRepair ? .structuralRepair(Set(paths)) : .article(nil)

      XCTAssertThrowsError(try service.write(preview: preview, rootURL: root, purpose: purpose)) {
        error in
        guard case .rollbackFailed? = error as? LocalPublishPreviewError else {
          return XCTFail("Expected rollback conflict, got \(error)")
        }
      }
      for target in targets {
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external editor content")
      }
      let journalURL = root.appendingPathComponent(LocalPublishPreviewService.transactionFileName)
      let journalData = try Data(contentsOf: journalURL)
      let transaction = try JSONDecoder().decode(LocalPublishTransaction.self, from: journalData)
      XCTAssertEqual(transaction.phase, .manualRecoveryRequired)
      XCTAssertEqual(service.interruptedTransactionIssue(at: root)?.severity, .error)
      XCTAssertThrowsError(try service.recoverInterruptedTransaction(at: root))
      XCTAssertEqual(try Data(contentsOf: journalURL), journalData)
      for target in targets {
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external editor content")
      }
      XCTAssertEqual(
        try String(
          contentsOf: URL(fileURLWithPath: transaction.rollbackDirectoryPath)
            .appendingPathComponent("0-backup"), encoding: .utf8), "original")
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "StructuralProtection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private final class ExternalEditDuringBackupFileManager: FileManager, @unchecked Sendable {
  let target: URL

  init(target: URL) {
    self.target = target
    super.init()
  }

  override func copyItem(at source: URL, to destination: URL) throws {
    try super.copyItem(at: source, to: destination)
    if source == target
      && destination.deletingLastPathComponent().lastPathComponent
        .hasPrefix(".repopress-local-publish-rollback-")
    {
      try "external editor content".write(to: target, atomically: true, encoding: .utf8)
    }
  }
}

private final class ExternalEditAfterWriteFileManager: FileManager, @unchecked Sendable {
  let targets: [URL]

  init(targets: [URL]) {
    self.targets = targets
    super.init()
  }

  override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?)
    -> Bool
  {
    if path == targets[0].path,
      (try? String(contentsOf: targets[0], encoding: .utf8)) == "intended payload"
    {
      for target in targets {
        // This hook models an external editor between our atomic write and
        // the writer's first post-write observation.
        do {
          try "external editor content".write(to: target, atomically: true, encoding: .utf8)
        } catch {
          XCTFail("Failed to inject the external edit: \(error)")
        }
      }
    }
    return super.fileExists(atPath: path, isDirectory: isDirectory)
  }
}
