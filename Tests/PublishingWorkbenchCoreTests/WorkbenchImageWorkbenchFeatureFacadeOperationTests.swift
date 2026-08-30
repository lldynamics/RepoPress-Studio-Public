import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchImageWorkbenchFeatureFacadeOperationTests: XCTestCase {
  func testResourceOperationLockSurvivesFacadeReuseAndRejectsSameProfileReentry() throws {
    let store = makeIsolatedStore()
    let facade = store.imageWorkbench
    let profileID = store.activeProfileID
    XCTAssertEqual(facade.assetResourceOperationCompletionRevision(for: profileID), 0)

    let operationID = try XCTUnwrap(
      facade.beginAssetResourceOperation(
        for: profileID,
        loadingDetail: "validating files"
      )
    )

    XCTAssertTrue(facade === store.imageWorkbench)
    XCTAssertTrue(facade.hasActiveAssetResourceOperation(for: profileID))
    XCTAssertTrue(facade.isCurrentAssetResourceOperation(operationID, for: profileID))
    XCTAssertEqual(
      facade.assetResourceOperationPresentation(for: profileID),
      .loading(detail: "validating files")
    )
    XCTAssertNil(
      facade.beginAssetResourceOperation(for: profileID, loadingDetail: "duplicate")
    )

    facade.finishAssetResourceOperation(
      operationID,
      for: profileID,
      presentation: .success(detail: "moved 2 files")
    )
    let laterConsumer = store.imageWorkbench
    XCTAssertEqual(facade.assetResourceOperationCompletionRevision(for: profileID), 1)
    XCTAssertEqual(
      laterConsumer.assetResourceOperationPresentation(for: profileID),
      .success(detail: "moved 2 files")
    )
  }

  func testResourceOperationLockIsProfileScopedAndOnlyMatchingTokenCanFinishIt() throws {
    let store = makeIsolatedStore()
    let facade = store.imageWorkbench
    let firstProfileID = UUID()
    let secondProfileID = UUID()
    let firstOperationID = try XCTUnwrap(
      facade.beginAssetResourceOperation(for: firstProfileID, loadingDetail: "cleanup")
    )
    let secondOperationID = try XCTUnwrap(
      facade.beginAssetResourceOperation(for: secondProfileID, loadingDetail: "compress")
    )

    facade.finishAssetResourceOperation(
      UUID(),
      for: firstProfileID,
      presentation: .failure(reason: "stale result")
    )
    XCTAssertTrue(facade.hasActiveAssetResourceOperation(for: firstProfileID))
    XCTAssertTrue(facade.hasActiveAssetResourceOperation(for: secondProfileID))
    XCTAssertEqual(facade.assetResourceOperationCompletionRevision(for: firstProfileID), 0)
    XCTAssertEqual(
      facade.assetResourceOperationPresentation(for: firstProfileID),
      .loading(detail: "cleanup")
    )

    facade.finishAssetResourceOperation(
      firstOperationID,
      for: firstProfileID,
      presentation: .partialSuccess(detail: "one item needs review")
    )
    XCTAssertFalse(facade.hasActiveAssetResourceOperation(for: firstProfileID))
    XCTAssertEqual(facade.assetResourceOperationCompletionRevision(for: firstProfileID), 1)
    XCTAssertEqual(
      facade.assetResourceOperationPresentation(for: firstProfileID),
      .partialSuccess(detail: "one item needs review")
    )
    XCTAssertTrue(
      facade.isCurrentAssetResourceOperation(secondOperationID, for: secondProfileID)
    )

    facade.finishAssetResourceOperation(
      secondOperationID,
      for: secondProfileID,
      presentation: .failure(reason: "disk is full")
    )
    XCTAssertFalse(facade.hasActiveAssetResourceOperation(for: secondProfileID))
    XCTAssertEqual(
      facade.assetResourceOperationPresentation(for: secondProfileID),
      .failure(reason: "disk is full")
    )
  }

  private func makeIsolatedStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("image-workbench-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }
}
