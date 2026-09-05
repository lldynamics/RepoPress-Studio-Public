import PublishingGitCore
import XCTest

@testable import PersonalSitePublisherMac

final class RepositorySafeSyncPresentationTests: XCTestCase {
  func testStrictlyBehindBranchUsesFastForwardReview() {
    let presentation = makePresentation(ahead: 0, behind: 3)

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.reviewKind, .fastForward)
    XCTAssertTrue(presentation.help.contains("确认前不改变 HEAD"))
  }

  func testDivergedBranchUsesReviewedRebaseInsteadOfFastForward() {
    let presentation = makePresentation(ahead: 2, behind: 3)

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.reviewKind, .rebase)
    XCTAssertEqual(presentation.title, "审阅并变基同步…")
  }

  func testOnlyAheadBranchDoesNotOfferPullOrRebase() {
    let presentation = makePresentation(ahead: 2, behind: 0)

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertNil(presentation.reviewKind)
    XCTAssertEqual(presentation.title, "本地提交待推送")
  }

  func testBusyRepositoryDisablesMutation() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 0, behind: 2),
      isScanning: false,
      hasPendingRecoveryOrLifecycle: false,
      isRepositoryOperationRunning: true,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertNil(presentation.reviewKind)
  }

  func testPendingLifecycleDisablesSyncEvenWhenNoOperationTaskIsRunning() {
    let presentation = RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: 1, behind: 2),
      isScanning: false,
      hasPendingRecoveryOrLifecycle: true,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertNil(presentation.reviewKind)
    XCTAssertTrue(presentation.help.contains("恢复记录"))
  }

  private func makePresentation(ahead: Int, behind: Int)
    -> RepositorySafeSyncActionPresentation
  {
    RepositorySafeSyncActionPresentation.make(
      hasRepository: true,
      branchStatus: branchStatus(ahead: ahead, behind: behind),
      isScanning: false,
      hasPendingRecoveryOrLifecycle: false,
      isRepositoryOperationRunning: false,
      isLocalMutationRunning: false,
      isRemoteOperationRunning: false
    )
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
