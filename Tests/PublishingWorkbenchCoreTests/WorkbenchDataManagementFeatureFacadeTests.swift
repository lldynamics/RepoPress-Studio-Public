import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchDataManagementFeatureFacadeTests: XCTestCase {
  func testFacadeIsStableAndIgnoresUnrelatedRootActivity() throws {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    XCTAssertTrue(facade === store.dataManagement)

    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.setPublishActionMessage("unrelated publish progress", status: .information)
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = "Body-only autosave should not redraw data management."
    store.updateDraft(draft)

    XCTAssertEqual(changes, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testFacadeNotifiesWhenRenderedCountsChange() {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    let initialCount = facade.draftCount
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    var addedDraft = ArticleDraft.empty(profile: store.activeProfile)
    addedDraft.title = "Data management count"
    store.setDrafts(store.drafts + [addedDraft])

    XCTAssertEqual(facade.draftCount, initialCount + 1)
    XCTAssertEqual(changes, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testFacadeTracksKnowledgeBusyStateWithoutRootObservation() {
    let store = makeIsolatedStore()
    let facade = store.dataManagement
    var changes = 0
    let cancellable = facade.objectWillChange.sink { changes += 1 }

    store.knowledge.isBusy = true

    XCTAssertTrue(facade.isKnowledgeBusy)
    XCTAssertEqual(changes, 1)
    withExtendedLifetime(cancellable) {}
  }

  private func makeIsolatedStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("data-management-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }
}
