import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishOutcomeInvariantTests: XCTestCase {
  func testReviewSuccessRequiresNonEmptyReviewURL() throws {
    let result = makeResult(mode: .reviewRequest, changedPaths: ["index.md"], commitSHA: "abc123")
    XCTAssertNoThrow(
      try result.withReviewURL("https://github.com/owner/site/pull/1").validatedForSuccess())
    XCTAssertThrowsError(try result.validatedForSuccess()) { error in
      guard let publishError = error as? RemoteRepositoryPublishError else {
        return XCTFail("Expected RemoteRepositoryPublishError, got \(error)")
      }
      guard
        case .partialPublish(
          let provider, let mode, let branch, let target, let paths, let sha, _) = publishError
      else {
        return XCTFail("Expected partialPublish, got \(error)")
      }
      XCTAssertEqual(provider, .github)
      XCTAssertEqual(mode, .reviewRequest)
      XCTAssertEqual(branch, "codex/review")
      XCTAssertEqual(target, "main")
      XCTAssertEqual(paths, ["index.md"])
      XCTAssertEqual(sha, "abc123")
    }
  }

  func testReviewWithoutChangesOrURLRequiresRecovery() {
    let result = makeResult(mode: .reviewRequest, changedPaths: [], commitSHA: nil)
    XCTAssertThrowsError(try result.validatedForSuccess()) { error in
      guard let publishError = error as? RemoteRepositoryPublishError else {
        return XCTFail("Expected RemoteRepositoryPublishError, got \(error)")
      }
      guard case .reviewRecoveryUnavailable = publishError else {
        return XCTFail("Expected reviewRecoveryUnavailable, got \(error)")
      }
    }
  }

  func testReviewRejectsBlankAndNonHTTPURLs() {
    let result = makeResult(
      mode: .reviewRequest,
      changedPaths: ["index.md"],
      commitSHA: "abc123"
    )
    for invalidURL in ["   ", "pull/1", "javascript:alert(1)"] {
      XCTAssertThrowsError(try result.withReviewURL(invalidURL).validatedForSuccess()) { error in
        guard let publishError = error as? RemoteRepositoryPublishError,
          case .partialPublish = publishError
        else {
          return XCTFail("Expected partialPublish for \(invalidURL), got \(error)")
        }
      }
    }
  }

  func testNonReviewModesDoNotRequireReviewURL() throws {
    for mode in [RemoteRepositoryPublishMode.directCommit, .previewBranch] {
      XCTAssertNoThrow(
        try makeResult(mode: mode, changedPaths: ["index.md"], commitSHA: "abc123")
          .validatedForSuccess())
    }
  }

  func testCompletedMessagesPreserveLifecycleBoundaries() {
    XCTAssertTrue(
      RemoteRepositoryPublishMode.directCommit.completedProgressMessage.contains("部署待验证"))
    XCTAssertTrue(
      RemoteRepositoryPublishMode.reviewRequest.completedProgressMessage.contains("等待合并"))
    XCTAssertTrue(
      RemoteRepositoryPublishMode.reviewRequest.completedProgressMessage.contains("尚未部署"))
    XCTAssertTrue(
      RemoteRepositoryPublishMode.previewBranch.completedProgressMessage.contains("不影响正式分支"))
  }

  private func makeResult(
    mode: RemoteRepositoryPublishMode,
    changedPaths: [String],
    commitSHA: String?
  ) -> RemoteRepositoryPublishResult {
    RemoteRepositoryPublishResult(
      provider: .github,
      mode: mode,
      branchName: mode == .directCommit ? "main" : "codex/review",
      targetBranch: "main",
      changedPaths: changedPaths,
      commitSHA: commitSHA
    )
  }
}

extension RemoteRepositoryPublishResult {
  fileprivate func withReviewURL(_ reviewURL: String) -> Self {
    var copy = self
    copy.reviewURL = reviewURL
    return copy
  }
}
