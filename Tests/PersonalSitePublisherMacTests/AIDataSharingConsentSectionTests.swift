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

  func testRemoteMasterOffWithExistingGrantRendersRetainedGrantState() {
    let presentation = AIDataSharingConsentPresentation(
      providerName: "Remote",
      destination: "api.example.com",
      destinationState: .remote,
      isRemoteAIEnabled: false,
      isGranted: false,
      hasDestinationGrant: true
    )

    XCTAssertEqual(
      AIDataSharingConsentSectionMode(presentation: presentation),
      .remote(isGranted: false)
    )
    XCTAssertTrue(presentation.hasDestinationGrant)
    XCTAssertFalse(presentation.isGranted)
  }

  func testCodexAccountBindingMismatchIsPresentedAsReauthorization() {
    let presentation = AIDataSharingConsentPresentation(
      providerName: "Codex / ChatGPT",
      destination: "Codex / ChatGPT",
      destinationState: .remote,
      isGranted: false,
      hasDestinationGrant: true,
      requiresAccountReauthorization: true
    )

    XCTAssertEqual(
      AIDataSharingConsentSectionMode(presentation: presentation),
      .remote(isGranted: false)
    )
    XCTAssertTrue(presentation.requiresAccountReauthorization)
  }

  func testCodexConsentSectionDelegatesAccountStateToLiveAccountSection() {
    let presentation = AIDataSharingConsentPresentation(
      providerName: "Codex / ChatGPT",
      destination: "Codex / ChatGPT",
      destinationState: .remote,
      isGranted: true,
      hasDestinationGrant: true
    )

    XCTAssertEqual(
      AIDataSharingConsentSectionMode(
        presentation: presentation,
        isCodexAppServer: true
      ),
      .codexManaged(hasDestinationGrant: true)
    )
  }

  @MainActor
  func testEnableRemoteAIAndGrantOpensMasterBeforeGrantingDestination() {
    var calls: [String] = []
    let section = AIDataSharingConsentSection(
      presentation: AIDataSharingConsentPresentation(
        providerName: "Remote",
        destination: "api.example.com",
        destinationState: .remote,
        isRemoteAIEnabled: false,
        isGranted: false
      ),
      setRemoteAIEnabled: { enabled in
        calls.append("enabled:\(enabled)")
      },
      grantConsent: {
        calls.append("grant")
      },
      revokeConsent: {}
    )

    section.enableRemoteAIAndGrant()

    XCTAssertEqual(calls, ["enabled:true", "grant"])
  }
}
