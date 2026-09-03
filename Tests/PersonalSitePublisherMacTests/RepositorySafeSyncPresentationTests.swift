import PublishingGitCore
import XCTest

@testable import PersonalSitePublisherMac

final class RepositorySafeSyncPresentationTests: XCTestCase {
  func testEnablesReviewForStrictlyBehindBranchWhenRepositoryIsIdle() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 0, behind: 3),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "审阅并安全同步远端…")
    XCTAssertTrue(presentation.help.contains("确认前不改变 HEAD"))
    XCTAssertEqual(presentation.reviewKind, .fastForward)
  }

  func testOffersRebaseReviewWhenBranchIsDiverged() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 2, behind: 3),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "审阅并变基同步…")
    XCTAssertEqual(presentation.reviewKind, .rebase)
    XCTAssertTrue(presentation.help.contains("临时封存"))
  }

  func testDisablesReviewWhenBranchIsOnlyLocallyAhead() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 1, behind: 0),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertNil(presentation.reviewKind)
    XCTAssertTrue(presentation.help.contains("无需先拉取或变基"))
  }

  func testDisablesReviewWithoutUpstreamOrWhileAnotherOperationRuns() {
    let missingUpstream = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: nil,
        aheadCount: 0,
        behindCount: 3
      ),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )
    XCTAssertFalse(missingUpstream.isEnabled)
    XCTAssertTrue(missingUpstream.help.contains("upstream"))

    let busy = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 0, behind: 3),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: true,
      isRemoteOperationRunning: false
    )
    XCTAssertFalse(busy.isEnabled)
    XCTAssertTrue(busy.help.contains("正在进行"))
  }

  func testShowsSynchronizedStateWhenNoCommitsAreBehind() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 0, behind: 0),
      isScanning: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "当前分支已同步")
    XCTAssertNil(presentation.reviewKind)
  }

  private func branchStatus(ahead: Int, behind: Int) -> RepositoryBranchStatus {
    RepositoryBranchStatus(
      branchName: "main",
      upstreamName: "origin/main",
      aheadCount: ahead,
      behindCount: behind
    )
  }
}
