import PublishingDomainContracts
import XCTest

@testable import PersonalSitePublisherMac

final class RepositoryImageBrowserPresentationTests: XCTestCase {
  func testProjectionCancellationStopsFilteringBeforeAllAssetsAreVisited() {
    let assets = projectionAssets(count: 200)
    var checks = 0
    XCTAssertThrowsError(
      try RepositoryImageBrowserProjection.project(
        assets, scope: .all, includesSubfolders: true, query: "", filter: .all,
        sortOrder: .nameAsc,
        checkCancellation: {
          checks += 1
          if checks == 10 { throw CancellationError() }
        })
    ) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(checks, 10)
  }

  func testProjectionCancellationCanInterruptSorting() {
    let assets = projectionAssets(count: 200)
    var checks = 0
    // One initial check, one per filtered asset, then the first sort check.
    let firstSortCheck = assets.count + 2
    XCTAssertThrowsError(
      try RepositoryImageBrowserProjection.project(
        assets, query: "", filter: .all, sortOrder: .nameAsc,
        checkCancellation: {
          checks += 1
          if checks == firstSortCheck { throw CancellationError() }
        })
    ) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(checks, firstSortCheck)
  }

  func testCancellableProjectionPreservesScopeFilteringAndOrdering() throws {
    let assets = projectionAssets(count: 40)
    let expected = RepositoryImageBrowserProjection.project(
      assets, scope: .folder("static"), includesSubfolders: true,
      query: "photo", filter: .all, sortOrder: .nameDesc)
    let actual = try RepositoryImageBrowserProjection.project(
      assets, scope: .folder("static"), includesSubfolders: true,
      query: "photo", filter: .all, sortOrder: .nameDesc,
      checkCancellation: { try Task.checkCancellation() })
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(actual.count, 40)
  }

  private func projectionAssets(count: Int) -> [RepositoryImageAsset] {
    (0..<count).reversed().map { index in
      RepositoryImageAsset(
        repositoryPath: "static/photo\(index).png", absoluteFilePath: "/tmp/photo\(index).png",
        filename: "photo\(index).png", fileExtension: "png", byteSize: 12,
        modifiedAt: nil, references: [])
    }
  }

  func testPresentationStateDistinguishesPreparingInventoryEmptyAndFilteredEmpty() {
    XCTAssertEqual(
      .preparing,
      RepositoryImageBrowserPresentationState.resolve(
        isLoading: true, inventoryCount: 0, projectedCount: 0))
    XCTAssertEqual(
      .inventoryEmpty,
      RepositoryImageBrowserPresentationState.resolve(
        isLoading: false, inventoryCount: 0, projectedCount: 0))
    XCTAssertEqual(
      .filteredEmpty,
      RepositoryImageBrowserPresentationState.resolve(
        isLoading: false, inventoryCount: 3, projectedCount: 0))
  }

  func testProjectionCanDistinguishInventoryFromFilterEmpty() {
    let asset = RepositoryImageAsset(
      repositoryPath: "static/photo.png", absoluteFilePath: "/tmp/photo.png", filename: "photo.png",
      fileExtension: "png", byteSize: 12, modifiedAt: nil, references: []
    )
    XCTAssertEqual(
      RepositoryImageBrowserView.project(
        [asset], query: "", filter: .unregistered, sortOrder: .nameAsc
      ).count,
      1
    )
    XCTAssertTrue(
      RepositoryImageBrowserView.project(
        [asset], query: "missing", filter: .all, sortOrder: .nameAsc
      ).isEmpty
    )
  }
}
