import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class RepositoryAccessibilityIdentifierTests: XCTestCase {
  func testRepositoryFileIdentifierTokenIsStableAcrossStatusChangesAndHidesPath() {
    let path = "content/posts/private-client-note.md"
    let modified = RepositoryChangedFile(status: " M", path: path, kind: .modified)
    let staged = RepositoryChangedFile(status: "M ", path: path, kind: .modified)
    let other = RepositoryChangedFile(
      status: " M",
      path: "content/posts/another-note.md",
      kind: .modified
    )

    XCTAssertEqual(modified.accessibilityIdentifierToken, staged.accessibilityIdentifierToken)
    XCTAssertNotEqual(modified.accessibilityIdentifierToken, other.accessibilityIdentifierToken)
    XCTAssertFalse(modified.accessibilityIdentifierToken.contains("private-client-note"))
  }
}
