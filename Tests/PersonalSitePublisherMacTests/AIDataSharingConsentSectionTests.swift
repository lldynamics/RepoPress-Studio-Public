import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class AIDataSharingConsentSectionTests: XCTestCase {
  func testUnconfiguredDestinationDoesNotRenderAsLocalService() {
    let presentation = AIDataSharingConsentPresentation(
      providerName: "Custom",
      destination: "",
      destinationState: .unconfigured,
      isGranted: false
    )

    XCTAssertEqual(
      AIDataSharingConsentSectionMode(presentation: presentation),
      .unconfigured
    )
    XCTAssertNotEqual(
      AIDataSharingConsentSectionMode(presentation: presentation),
      .local
    )
  }

  func testLoopbackDestinationRendersAsLocalService() {
    let presentation = AIDataSharingConsentPresentation(
      providerName: "Local",
      destination: "127.0.0.1:11434",
      destinationState: .local,
      isGranted: true
    )

    XCTAssertEqual(
      AIDataSharingConsentSectionMode(presentation: presentation),
      .local
    )
  }
}
