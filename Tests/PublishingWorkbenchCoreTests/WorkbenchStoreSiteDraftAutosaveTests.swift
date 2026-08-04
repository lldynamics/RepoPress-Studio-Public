import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreSiteDraftAutosaveTests: XCTestCase {
  func testCreatedAndEditedSiteDraftIsWrittenIntoProject() async throws {
    let rootURL = try temporaryDirectory(prefix: "site-draft-project")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("app-data/workbench.json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.localRepositoryBookmarkData = nil
    }
    await store.waitForPendingSiteDraftFileWrites()

    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "实时保存验收"
    draft.slug = "live-save-acceptance"
    draft.bodyMarkdown = "第一版正文"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()

    draft = try XCTUnwrap(store.selectedDraft)
    let repositoryPath = try XCTUnwrap(draft.repositoryPath)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    var contents = try String(contentsOf: destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("第一版正文"))
    XCTAssertEqual(
      store.siteDraftFileSaveStates[draft.id],
      .saved(
        repositoryPath: repositoryPath,
        savedAt: store.siteDraftFileSaveStates[draft.id]?.savedAtForTesting ?? .distantPast)
    )

    draft.bodyMarkdown = "第二版正文"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()
    contents = try String(contentsOf: destinationURL, encoding: .utf8)
    XCTAssertTrue(contents.contains("第二版正文"))
    XCTAssertFalse(contents.contains("第一版正文"))
  }

  func testGeneralDraftRemainsAppOnly() async throws {
    let rootURL = try temporaryDirectory(prefix: "general-draft-project")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json")
      )
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.localRepositoryBookmarkData = nil
    }
    await store.waitForPendingSiteDraftFileWrites()
    let projectFilesBefore = try relativeProjectFiles(in: rootURL)

    store.createGeneralDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "只存软件"
    draft.slug = "app-only"
    draft.bodyMarkdown = "不应自动写进项目"
    store.updateDraft(draft)
    await store.waitForPendingSiteDraftFileWrites()

    XCTAssertTrue(try XCTUnwrap(store.selectedDraft).isGeneralDraft)
    XCTAssertNil(store.selectedDraft?.repositoryPath)
    XCTAssertNil(store.siteDraftFileSaveStates[draft.id])
    XCTAssertEqual(try relativeProjectFiles(in: rootURL), projectFilesBefore)
  }

  private func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func relativeProjectFiles(in rootURL: URL) throws -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    else {
      return []
    }
    return try enumerator.compactMap { element in
      guard let url = element as? URL,
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      else {
        return nil
      }
      return String(url.path.dropFirst(rootURL.path.count + 1))
    }.sorted()
  }
}

extension SiteDraftFileSaveState {
  fileprivate var savedAtForTesting: Date? {
    guard case .saved(_, let savedAt) = self else { return nil }
    return savedAt
  }
}
