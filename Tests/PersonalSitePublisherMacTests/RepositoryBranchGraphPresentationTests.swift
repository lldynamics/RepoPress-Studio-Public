import PublishingGitCore
import XCTest
@testable import PersonalSitePublisherMac

final class RepositoryBranchGraphPresentationTests: XCTestCase {
  func testDivergedPresentationExposesCommonAndBothTips() {
    let value = RepositoryBranchGraphPresentation(
      branchName: "main", upstreamName: "origin/main", aheadCount: 2, behindCount: 3,
      localHeadSHA: "local-123456789012", remoteHeadSHA: "remote-123456789012"
    )

    XCTAssertTrue(value.isDiverged)
    XCTAssertEqual(value.localLabel, "Local (Ahead 2)")
    XCTAssertEqual(value.remoteLabel, "Remote (Behind 3)")
    XCTAssertEqual(value.nodes.map(\.kind), [.common, .local, .remote])
    XCTAssertTrue(value.accessibilitySummary.contains("已分叉"))
  }

  func testSynchronizedPresentationKeepsOneSharedNode() {
    let value = RepositoryBranchGraphPresentation(
      status: RepositoryBranchStatus(branchName: "main", upstreamName: "origin/main"),
      localHeadSHA: "abcdef1234567890", remoteHeadSHA: "abcdef1234567890"
    )

    XCTAssertTrue(value.isSynchronized)
    XCTAssertEqual(value.nodes.count, 1)
    XCTAssertEqual(value.commonSHA, "abcdef1234567890")
    XCTAssertTrue(value.accessibilitySummary.contains("已同步"))
  }

  func testNegativeDistancesAreClampedAndMissingNamesHaveFallbacks() {
    let value = RepositoryBranchGraphPresentation(
      branchName: "", upstreamName: nil, aheadCount: -1, behindCount: -2
    )

    XCTAssertEqual(value.branchName, "当前分支")
    XCTAssertEqual(value.upstreamName, "远端分支")
    XCTAssertEqual(value.aheadCount, 0)
    XCTAssertEqual(value.behindCount, 0)
  }
}
