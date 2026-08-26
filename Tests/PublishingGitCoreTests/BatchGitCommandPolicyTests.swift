import Foundation
import XCTest

@testable import PublishingGitCore

final class BatchGitCommandPolicyTests: XCTestCase {
  func testBuildsSingleItemCommitWithTitleAndQuotesShellSyntax() {
    let item = BatchGitCommandItem(
      title: "Title $(touch /tmp/should-not-run) `id` 'quoted'\nnext",
      repositoryPaths: ["content/posts/safe.md", "static/images/a b.png"]
    )

    XCTAssertEqual(
      BatchGitCommandPolicy().directCommitCommand(
        rootPath: "/tmp/site $(touch /tmp/should-not-run)",
        items: [item]
      ),
      "cd '/tmp/site $(touch /tmp/should-not-run)' && git add 'content/posts/safe.md' 'static/images/a b.png' && git commit -m 'Publish: Title $(touch /tmp/should-not-run) `id` '\\''quoted'\\''\nnext'"
    )
  }

  func testBuildsMultipleItemCommandsWithUniqueSortedPaths() {
    let items = [
      BatchGitCommandItem(
        title: "First",
        repositoryPaths: ["z.md", "shared.png", "a.md"]
      ),
      BatchGitCommandItem(
        title: "Second",
        repositoryPaths: ["shared.png", "b.md"]
      ),
    ]
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let policy = BatchGitCommandPolicy()

    XCTAssertEqual(
      policy.directCommitCommand(rootPath: "/tmp/site", items: items),
      "cd '/tmp/site' && git add 'a.md' 'b.md' 'shared.png' 'z.md' && git commit -m 'Publish: 2 articles'"
    )
    XCTAssertEqual(
      policy.reviewBranchCommands(rootPath: "/tmp/site", items: items, now: now),
      [
        "cd '/tmp/site'",
        "git switch -c 'publish/batch-20260829-1040-2-articles'",
        "git add 'a.md' 'b.md' 'shared.png' 'z.md'",
        "git commit -m 'Publish: 2 articles'",
        "git push -u origin 'publish/batch-20260829-1040-2-articles'",
      ]
    )
  }

  func testReturnsEmptyCommandsForEmptyInputs() {
    let policy = BatchGitCommandPolicy()

    XCTAssertNil(policy.directCommitCommand(rootPath: nil, items: []))
    XCTAssertNil(policy.directCommitCommand(rootPath: " ", items: [item()]))
    XCTAssertTrue(policy.reviewBranchCommands(rootPath: "/tmp/site", items: []).isEmpty)
    XCTAssertEqual(
      policy.reviewBranchName(for: [], now: Date(timeIntervalSince1970: 1_788_000_000)),
      "publish/batch-20260829-1040-0-articles"
    )
  }

  func testUsesUTCForDeterministicBranchNames() {
    let now = Date(timeIntervalSince1970: 1_788_000_000)

    XCTAssertEqual(
      BatchGitCommandPolicy().reviewBranchName(for: [item()], now: now),
      "publish/batch-20260829-1040-1-articles"
    )
  }

  private func item() -> BatchGitCommandItem {
    BatchGitCommandItem(title: "Ready", repositoryPaths: ["content/ready.md"])
  }
}
