import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class LocalSitePreviewTrustConfirmationTests: XCTestCase {
  func testPresentationShowsExactRepositoryAndCommandWithNativeCodeWarning() {
    let request = makeRequest()

    let presentation = LocalSitePreviewTrustConfirmationPresentation(request: request)

    XCTAssertEqual(presentation.repositoryPath, request.repositoryPath)
    XCTAssertEqual(presentation.command, request.command)
    XCTAssertFalse(presentation.title.isEmpty)
    XCTAssertFalse(presentation.repositoryLabel.isEmpty)
    XCTAssertFalse(presentation.commandLabel.isEmpty)
    XCTAssertTrue(presentation.riskMessage.contains("执行仓库中的代码"))
    XCTAssertFalse(presentation.confirmTitle.isEmpty)
    XCTAssertFalse(presentation.cancelTitle.isEmpty)
  }

  func testBothInteractiveEntryPointsPresentOnlyConfirmationDisposition() {
    let request = makeRequest()

    for entryPoint in LocalSitePreviewTrustEntryPoint.allCases {
      XCTAssertEqual(
        LocalSitePreviewTrustConfirmationPolicy.request(
          from: .needsConfirmation(request),
          entryPoint: entryPoint
        ),
        request
      )
      XCTAssertNil(
        LocalSitePreviewTrustConfirmationPolicy.request(
          from: .started,
          entryPoint: entryPoint
        )
      )
      XCTAssertNil(
        LocalSitePreviewTrustConfirmationPolicy.request(
          from: .failed("failed"),
          entryPoint: entryPoint
        )
      )
    }
  }

  func testRepositoryPrimaryActionRequiresTheSharedPanelCommand() {
    XCTAssertTrue(
      LocalSitePreviewTrustConfirmationPolicy.repositoryStartOpensConfirmationPanel(
        commandActionAvailable: true
      )
    )
    XCTAssertFalse(
      LocalSitePreviewTrustConfirmationPolicy.repositoryStartOpensConfirmationPanel(
        commandActionAvailable: false
      )
    )
  }

  private func makeRequest() -> LocalSitePreviewAuthorizationRequest {
    LocalSitePreviewAuthorizationRequest(
      profileID: UUID(),
      fingerprint: "fingerprint",
      repositoryPath: "/tmp/Trusted Site",
      command: "cd '/tmp/Trusted Site' && 'npm' 'run' 'dev'",
      siteKind: .astro
    )
  }
}
