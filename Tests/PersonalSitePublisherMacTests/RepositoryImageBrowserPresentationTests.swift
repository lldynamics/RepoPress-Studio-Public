import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class RepositoryImageBrowserPresentationTests: XCTestCase {
  func testPresentationStateDistinguishesPreparingInventoryEmptyAndFilteredEmpty() {
    XCTAssertEqual(.preparing, RepositoryImageBrowserPresentationState.resolve(isLoading: true, inventoryCount: 0, projectedCount: 0))
    XCTAssertEqual(.inventoryEmpty, RepositoryImageBrowserPresentationState.resolve(isLoading: false, inventoryCount: 0, projectedCount: 0))
    XCTAssertEqual(.filteredEmpty, RepositoryImageBrowserPresentationState.resolve(isLoading: false, inventoryCount: 3, projectedCount: 0))
  }

  func testProjectionCanDistinguishInventoryFromFilterEmpty() {
    let asset = RepositoryImageAsset(
      repositoryPath: "static/photo.png", absoluteFilePath: "/tmp/photo.png", filename: "photo.png",
      fileExtension: "png", byteSize: 12, modifiedAt: nil, references: []
    )
    XCTAssertEqual(
      RepositoryImageBrowserView.project([asset], query: "", filter: .unregistered, sortOrder: .nameAsc).count,
      1
    )
    XCTAssertTrue(
      RepositoryImageBrowserView.project([asset], query: "missing", filter: .all, sortOrder: .nameAsc).isEmpty
    )
  }
}
