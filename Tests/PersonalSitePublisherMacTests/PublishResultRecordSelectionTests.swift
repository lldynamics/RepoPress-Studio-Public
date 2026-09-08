import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishResultRecordSelectionTests: XCTestCase {
  func testResultUsesItsRecordIDInsteadOfLatestRelease() {
    let profileID = UUID()
    let draftID = UUID()
    let record = ReleaseRecord(
      kind: .remoteReviewRequest, title: "Review", summary: "", siteProfileID: profileID,
      draftID: draftID)
    let newer = ReleaseRecord(
      kind: .remoteDirectCommit, title: "Other operation", summary: "", siteProfileID: profileID,
      draftID: draftID)
    let result = RemoteRepositoryPublishResult(
      provider: .github, mode: .reviewRequest,
      branchName: "review", targetBranch: "main", changedPaths: [], commitSHA: "sha",
      releaseRecordID: record.id)
    XCTAssertEqual(
      PublishResultRecordSelection.recordID(
        result: result, records: [newer, record],
        previousRecordIDs: [], profileID: profileID, draftIDs: [draftID]), record.id)
    XCTAssertNil(
      PublishResultRecordSelection.recordID(
        result: result, records: [newer, record],
        previousRecordIDs: [], profileID: UUID(), draftIDs: [draftID]))
  }

  func testOnlyNewExactScopeFailureIsSelected() {
    let profileID = UUID()
    let draftID = UUID()
    let previous = ReleaseRecord(
      kind: .remotePublishFailure, title: "Old failure", summary: "", siteProfileID: profileID,
      draftID: draftID)
    let unrelated = ReleaseRecord(
      kind: .remotePublishFailure, title: "Unrelated", summary: "", siteProfileID: profileID,
      draftID: UUID())
    XCTAssertNil(
      PublishResultRecordSelection.recordID(
        result: nil, records: [unrelated, previous],
        previousRecordIDs: [previous.id], profileID: profileID, draftIDs: [draftID]))
    let current = ReleaseRecord(
      kind: .remotePublishFailure, title: "This operation", summary: "", siteProfileID: profileID,
      draftID: draftID)
    XCTAssertEqual(
      PublishResultRecordSelection.recordID(
        result: nil, records: [current, unrelated, previous],
        previousRecordIDs: [previous.id], profileID: profileID, draftIDs: [draftID]), current.id)
  }
}
