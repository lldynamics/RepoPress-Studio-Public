import XCTest

@testable import PersonalSitePublisherMac

final class DraftFullTextSearchActionTests: XCTestCase {
  func testRequestHandoffPreservesQueryAndGeneralDraftScope() {
    var received: DraftFullTextSearchRequest?
    let action = DraftFullTextSearchAction(
      open: { XCTFail("The request route should be preferred.") },
      openRequest: { received = $0 }
    )
    let request = DraftFullTextSearchRequest(
      query: "正文关键词",
      scope: .generalDrafts
    )

    action.open(request)

    XCTAssertEqual(received, request)
  }
}
