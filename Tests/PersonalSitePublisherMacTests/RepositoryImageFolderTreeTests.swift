import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingDomainContracts

final class RepositoryImageFolderTreeTests: XCTestCase {
  func testEmptyDirectoryIsRetained() {
    let tree = RepositoryImageFolderTree(
      assetRootPath: "static/images",
      directoryPaths: ["static/images", "static/images/empty"],
      imagePaths: []
    )

    XCTAssertEqual(tree.root.children.map(\.repositoryPath), ["static/images/empty"])
    XCTAssertEqual(tree.root.children[0].recursiveImageCount, 0)
  }

  func testNaturalOrderingAndDirectRecursiveCounts() {
    let tree = RepositoryImageFolderTree(
      assetRootPath: "static/images",
      directoryPaths: ["static/images/10", "static/images/2", "static/images/2/nested"],
      imagePaths: [
        "static/images/2/a.png", "static/images/2/nested/b.png", "static/images/10/c.png",
      ]
    )

    XCTAssertEqual(tree.root.children.map(\.name), ["2", "10"])
    let two = tree.node(withPath: "static/images/2")!
    XCTAssertEqual(two.directImageCount, 1)
    XCTAssertEqual(two.recursiveImageCount, 2)
    XCTAssertEqual(tree.node(withPath: "static/images/2/nested")?.directImageCount, 1)
  }

  func testDuplicateImagesCountOnceAndPrefixContainmentIsSegmentSafe() {
    let tree = RepositoryImageFolderTree(
      assetRootPath: "static/img",
      directoryPaths: ["static/images", "static/img/deep"],
      imagePaths: [
        "static/img/one.png",
        "static/img/one.png",
        "static/images/other.png",
      ]
    )

    XCTAssertEqual(tree.root.recursiveImageCount, 1)
    XCTAssertNil(tree.node(withPath: "static/images"))
  }

  func testDeepAncestorsAndFolderSearchIncludeAncestors() {
    let tree = RepositoryImageFolderTree(
      assetRootPath: "assets",
      directoryPaths: ["assets/a/b/c"],
      imagePaths: ["assets/a/b/c/photo.png"]
    )

    XCTAssertEqual(
      tree.allNodes.map(\.repositoryPath), ["assets", "assets/a", "assets/a/b", "assets/a/b/c"])
    XCTAssertEqual(
      tree.matchingPaths(query: "c"), ["assets", "assets/a", "assets/a/b", "assets/a/b/c"])
    XCTAssertEqual(
      tree.expandedPaths(for: "c"), ["assets", "assets/a", "assets/a/b", "assets/a/b/c"])
  }
}
