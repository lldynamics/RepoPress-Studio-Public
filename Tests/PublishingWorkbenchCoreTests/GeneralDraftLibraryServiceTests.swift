import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testStoreCopiesArticleToAnotherPublishingSite() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let source = try XCTUnwrap(store.selectedDraft)
    let targetProfile = store.createProfile(named: "项目网站")

    let copied = try XCTUnwrap(store.copyDraft(source.id, toProfileID: targetProfile.id))

    XCTAssertEqual(copied.siteProfileID, targetProfile.id)
    XCTAssertEqual(copied.status, .draft)
    XCTAssertNil(copied.repositoryPath)
    XCTAssertNil(copied.repositorySHA)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertEqual(store.selectedSection, .writing)
  }
}

final class ExternalDraftSourceCodingTests: XCTestCase {
  func testDecodesSnapshotsWrittenBeforeDetachedFolderSupport() throws {
    let mappingID = UUID()
    let payload = Data(
      """
      {
        "mappingID": "\(mappingID.uuidString)",
        "relativePath": "inbox/idea.md",
        "importedTitle": "旧来源",
        "importedFingerprint": "fingerprint"
      }
      """.utf8
    )

    let source = try JSONDecoder().decode(ExternalDraftSource.self, from: payload)

    XCTAssertEqual(source.mappingID, mappingID)
    XCTAssertNil(source.detachedFolderPath)
    XCTAssertFalse(source.isDetached)
  }
}

@MainActor
final class ExternalDraftFolderSyncTests: XCTestCase {
  func testFolderScanRefreshWritebackAndConflictPreserveBothVersions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("external-draft-sync-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("vault-output", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("note.md")
    try Data("# First\n\nSource body\n".utf8).write(to: file)

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workspace.json"))
    )
    XCTAssertTrue(store.connectExternalDraftFolder(folder))
    let first = await store.scanExternalDraftFolder()
    XCTAssertNil(first.errorMessage)
    XCTAssertEqual(first.addedCount, 1)
    let imported = try XCTUnwrap(store.drafts.first { $0.externalDraftSource != nil })
    XCTAssertTrue(imported.isGeneralDraft)
    XCTAssertEqual(imported.title, "First")
    store.synchronizeDraftBodyEditorBuffer(with: imported)
    let originalEditorRevision = store.draftBodyEditorBuffer(for: imported.id).revision
    XCTAssertTrue(store.connectExternalDraftFolder(folder))
    let repeatedScan = await store.scanExternalDraftFolder()
    XCTAssertEqual(repeatedScan.addedCount, 0)

    try Data("# First\n\nChanged outside first\n".utf8).write(to: file)
    let firstRefresh = await store.scanExternalDraftFolder()
    XCTAssertEqual(firstRefresh.refreshedCount, 1)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: imported.id).bodyMarkdown,
      "# First\n\nChanged outside first\n"
    )
    XCTAssertGreaterThan(
      store.draftBodyEditorBuffer(for: imported.id).revision, originalEditorRevision)
    var staleEditor = imported
    staleEditor.summary = "Edited metadata"
    XCTAssertTrue(store.updateDraftFromEditor(staleEditor))
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# First\n\nChanged outside first\n"
    )

    try Data("# Second\n\nChanged outside\n".utf8).write(to: file)
    let refreshed = await store.scanExternalDraftFolder()
    XCTAssertEqual(refreshed.refreshedCount, 1)
    XCTAssertEqual(store.draft(for: imported.id)?.title, "Second")

    var edited = try XCTUnwrap(store.draft(for: imported.id))
    edited.bodyMarkdown = "# Second\n\nChanged in RepoPress\n"
    store.updateDraft(edited)
    XCTAssertTrue(store.flushPendingChanges())
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited.bodyMarkdown)

    edited = try XCTUnwrap(store.draft(for: imported.id))
    edited.bodyMarkdown = "# Second\n\nLocal unsaved change\n"
    store.updateDraft(edited)
    try Data("# Third\n\nConcurrent outside change\n".utf8).write(to: file)
    let conflict = await store.scanExternalDraftFolder()
    XCTAssertEqual(conflict.conflictCount, 1)
    XCTAssertEqual(store.draft(for: imported.id)?.bodyMarkdown, edited.bodyMarkdown)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8),
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertTrue(store.externalDraftConflicts.contains(imported.id))
    let resolved = await store.keepLocalCopyAndAcceptExternal(draftID: imported.id)
    XCTAssertTrue(resolved)
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: imported.id).bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertTrue(
      store.drafts.contains {
        $0.externalDraftSource == nil && $0.bodyMarkdown == edited.bodyMarkdown
          && $0.title.contains("本地冲突副本")
      })
    XCTAssertEqual(store.pendingExternalDraftWriteCount, 0)

    store.disconnectExternalDraftFolder()
    XCTAssertNil(store.draft(for: imported.id)?.externalDraftSource)
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
  }
}

final class ExternalDraftScanBudgetTests: XCTestCase {
  func testCumulativeBudgetAcceptsExactBoundaryAndRejectsExcess() throws {
    let root = try temporaryDirectory()
    try Data("abcd".utf8).write(to: root.appendingPathComponent("a.md"))
    try Data("efgh".utf8).write(to: root.appendingPathComponent("b.md"))
    let exact = ExternalDraftFolderService(limits: .init(totalSize: 8))
    XCTAssertEqual(try exact.scan(rootURL: root).count, 2)

    let smaller = ExternalDraftFolderService(limits: .init(totalSize: 7))
    XCTAssertThrowsError(try smaller.scan(rootURL: root)) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .totalSizeExceeded)
    }
  }

  func testDirectoryDepthIsBoundedEvenWithoutMarkdownFiles() throws {
    let root = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("first/second"), withIntermediateDirectories: true)
    XCTAssertTrue(
      try ExternalDraftFolderService(limits: .init(directoryDepth: 2))
        .scan(rootURL: root).isEmpty)
    XCTAssertThrowsError(
      try ExternalDraftFolderService(limits: .init(directoryDepth: 1)).scan(rootURL: root)
    ) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .directoryDepthExceeded)
    }
  }

  func testEntryBudgetIncludesUnrelatedFiles() throws {
    let root = try temporaryDirectory()
    for index in 0..<3 {
      try Data().write(to: root.appendingPathComponent("\(index).json"))
    }
    XCTAssertTrue(
      try ExternalDraftFolderService(limits: .init(entryCount: 3))
        .scan(rootURL: root).isEmpty)
    XCTAssertThrowsError(
      try ExternalDraftFolderService(limits: .init(entryCount: 2)).scan(rootURL: root)
    ) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .entryCountExceeded)
    }
  }

  func testFileAndFileCountLimitsRemainIndependent() throws {
    let root = try temporaryDirectory()
    try Data("abcd".utf8).write(to: root.appendingPathComponent("a.md"))
    XCTAssertThrowsError(
      try ExternalDraftFolderService(limits: .init(fileSize: 3)).scan(rootURL: root)
    ) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .fileTooLarge(relativePath: "a.md"))
    }
    try Data().write(to: root.appendingPathComponent("b.md"))
    XCTAssertThrowsError(
      try ExternalDraftFolderService(limits: .init(fileCount: 1)).scan(rootURL: root)
    ) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .fileCountExceeded)
    }
  }

  func testFileGrowthAfterMetadataReadCannotExceedRemainingBudget() throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("growing.md")
    try Data("a".utf8).write(to: file)
    var checks = 0
    let scanner = ExternalDraftFolderService(limits: .init(totalSize: 4))
    XCTAssertThrowsError(
      try scanner.scan(rootURL: root) {
        checks += 1
        // Start, enumeration, then the cancellation boundary immediately before reading.
        if checks == 3 { try Data("12345".utf8).write(to: file) }
      }
    ) {
      XCTAssertEqual($0 as? ExternalDraftFolderServiceError, .totalSizeExceeded)
    }
  }

  func testCancellationAfterAReadRejectsTheEntireScan() throws {
    let root = try temporaryDirectory()
    try Data("# Heading\nbody".utf8).write(to: root.appendingPathComponent("a.md"))
    var checks = 0
    XCTAssertThrowsError(
      try ExternalDraftFolderService().scan(rootURL: root) {
        checks += 1
        if checks == 4 { throw CancellationError() }
      }
    ) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertEqual(checks, 4)
  }

  @MainActor
  func testAsyncScanPropagatesParentCancellation() async throws {
    let root = try temporaryDirectory()
    try Data("body".utf8).write(to: root.appendingPathComponent("a.md"))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ExternalDraftFolderService().scanAsync(rootURL: root)
    }
    do {
      _ = try await task.value
      XCTFail("Cancelled scan must not return a snapshot")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testTitleScanPreservesFenceAndMixedLineEndingRules() throws {
    let root = try temporaryDirectory()
    let text = "\r\n```swift\r\n# Ignored\r\n```\r\nintro\u{2028}# Actual title ###\nbody"
    try Data(text.utf8).write(to: root.appendingPathComponent("title.md"))
    let file = try XCTUnwrap(ExternalDraftFolderService().scan(rootURL: root).first)
    XCTAssertEqual(file.title, "Actual title")
    XCTAssertEqual(file.markdown, text)
  }

  func testCancellationInterruptsLongPhysicalLineDuringTitleSearch() throws {
    let root = try temporaryDirectory()
    try Data(String(repeating: "a", count: 100_000).utf8)
      .write(to: root.appendingPathComponent("long.md"))
    var checks = 0
    XCTAssertThrowsError(
      try ExternalDraftFolderService().scan(rootURL: root) {
        checks += 1
        if checks == 8 { throw CancellationError() }
      }
    ) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(checks, 8)
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("external-scan-budget-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
