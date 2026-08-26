import XCTest
@testable import PublishingGitCore

final class RemoteReviewPolicyTests: XCTestCase {
  func testBranchCommandsQuoteShellSpecialCharacters() {
    let input = RemoteReviewBranchCommandInput(
      rootPath: "/tmp/site with space",
      branchName: "publish/o'hara;$(echo unsafe)",
      commitMessage: "Publish: O'Hara & review",
      repositoryPaths: [
        "content/hello world.md",
        "assets/o'hara.png",
      ]
    )

    XCTAssertEqual(
      RemoteReviewBranchCommandBuilder().buildCommands(for: input),
      [
        "cd '/tmp/site with space'",
        "git switch -c 'publish/o'\\''hara;$(echo unsafe)'",
        "git add 'content/hello world.md' 'assets/o'\\''hara.png'",
        "git commit -m 'Publish: O'\\''Hara & review'",
        "git push -u origin 'publish/o'\\''hara;$(echo unsafe)'",
      ]
    )
  }

  func testBranchCommandsPreserveInputPathOrder() {
    let input = RemoteReviewBranchCommandInput(
      rootPath: "/tmp/site",
      branchName: "publish/article",
      commitMessage: "Publish article",
      repositoryPaths: ["z.md", "a.md"]
    )

    XCTAssertEqual(
      RemoteReviewBranchCommandBuilder().buildCommands(for: input)[2],
      "git add 'z.md' 'a.md'"
    )
  }
}
