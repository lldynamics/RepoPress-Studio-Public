import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceEvidenceTests: RemoteRepositoryPublishServiceTestCase {

  func testRemotePublishResultPresentationBuildsStableClipboardSummary() {
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "https://gitlab.example.com/api/v4",
      mode: .reviewRequest,
      branchName: "publish/post",
      targetBranch: "main",
      changedPaths: ["content/posts/post.md", "static/images/post.png"],
      commitSHA: "1234567890abcdef",
      reviewURL: "https://gitlab.com/group/site/-/merge_requests/5",
      reviewTitle: "Publish: Post"
    )

    XCTAssertEqual(result.shortCommitSHA, "12345678")
    XCTAssertEqual(result.displayTitle, "GitLab \(CoreL10n.text("线上 PR/MR"))")
    XCTAssertEqual(result.branchSummary, "publish/post -> main")
    XCTAssertTrue(result.clipboardSummary.contains(CoreL10n.format("仓库：%@", "group/site")))
    XCTAssertTrue(
      result.clipboardSummary.contains(CoreL10n.format("Commit：%@", "1234567890abcdef")))
    XCTAssertTrue(
      result.clipboardSummary.contains(
        CoreL10n.format("PR/MR：%@", "https://gitlab.com/group/site/-/merge_requests/5")))
    XCTAssertTrue(result.clipboardSummary.contains("- content/posts/post.md"))
    XCTAssertTrue(result.clipboardSummary.contains("- static/images/post.png"))
  }

  func testRemotePublishResultDecodesLegacyPayloadWithoutRepositoryContext() throws {
    let data = """
      {
        "provider": "github",
        "mode": "directCommit",
        "branchName": "main",
        "targetBranch": "main",
        "changedPaths": ["content/posts/post.md"],
        "commitSHA": "abc123"
      }
      """.data(using: .utf8)!

    let result = try JSONDecoder().decode(RemoteRepositoryPublishResult.self, from: data)

    XCTAssertNil(result.repositoryName)
    XCTAssertNil(result.apiBaseURL)
  }
}
