import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class SiteStarterDeploymentLinkTests: XCTestCase {
  func testFirstPushLinkIsPinnedToActualRemoteAndCommit() {
    let sha = String(repeating: "a", count: 40)
    let result = SiteStarterPushResult(
      rootPath: "/tmp/site", branch: "main",
      remoteURL: "https://github.com/example/site.git", commitSHA: sha,
      committedPaths: ["README.md"], output: "")
    XCTAssertEqual(
      SiteStarterDeploymentLink.commitURL(for: result)?.absoluteString,
      "https://github.com/example/site/commit/" + sha)
    var unsafe = result
    unsafe.remoteURL = "https://user:secret@github.com/example/site.git"
    XCTAssertNil(SiteStarterDeploymentLink.commitURL(for: unsafe))
    unsafe = result
    unsafe.commitSHA = "../main"
    XCTAssertNil(SiteStarterDeploymentLink.commitURL(for: unsafe))
  }
}
