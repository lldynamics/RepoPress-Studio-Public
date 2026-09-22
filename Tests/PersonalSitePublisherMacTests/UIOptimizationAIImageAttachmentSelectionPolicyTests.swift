import Foundation
import PublishingDomainContracts
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class UIOptimizationAIImageAttachmentSelectionPolicyTests: XCTestCase {
  func testMissingAttachmentIDsAreExcludedFromVisibleAndSendableSelection() {
    let availableID = UUID()
    let missingID = UUID()

    let validIDs = AIChatImageAttachmentSelectionPolicy.validSelection(
      [availableID, missingID],
      availableAttachmentIDs: [availableID]
    )

    XCTAssertEqual(validIDs, [availableID])
    XCTAssertFalse(validIDs.contains(missingID))
  }

  func testImageOnlyMessageWithOnlyMissingIDsHasNoSendableAttachment() {
    let validIDs = AIChatImageAttachmentSelectionPolicy.validSelection(
      [UUID()],
      availableAttachmentIDs: []
    )

    XCTAssertTrue(validIDs.isEmpty)
  }

  func testKnownMenuFailuresUseAttachmentMetadataWithoutReadingFiles() {
    let unsupported = DraftAttachment(
      originalFilename: "unsupported.tiff",
      relativePublishPath: "/images/unsupported.tiff",
      repositoryPath: "static/images/unsupported.tiff",
      byteSize: 0,
      sourceFilePath: "/path/that/does/not/exist/unsupported.tiff"
    )
    let oversized = DraftAttachment(
      originalFilename: "oversized.png",
      relativePublishPath: "/images/oversized.png",
      repositoryPath: "static/images/oversized.png",
      byteSize: Int64(AIPublishingChatImageAttachmentPresentation.maxAttachmentBytes + 1),
      sourceFilePath: "/path/that/does/not/exist/oversized.png"
    )

    XCTAssertTrue(
      AIChatImageAttachmentSelectionPolicy.knownFailureReason(for: unsupported)?
        .contains("格式不支持") == true
    )
    XCTAssertTrue(
      AIChatImageAttachmentSelectionPolicy.knownFailureReason(for: oversized)?
        .contains("超过") == true
    )
  }

  func testPruningCurrentConversationDoesNotClearAnotherConversationSelection() {
    let currentConversationID = UUID()
    let otherConversationID = UUID()
    let currentAttachmentID = UUID()
    let staleAttachmentID = UUID()
    let otherAttachmentID = UUID()
    var surfaceState = AIChatSurfaceState(surface: .inspector)
    surfaceState.setImageAttachmentIDs(
      [currentAttachmentID, staleAttachmentID],
      for: currentConversationID
    )
    surfaceState.setImageAttachmentIDs([otherAttachmentID], for: otherConversationID)

    let resolvedCurrentConversationID = AIChatImageAttachmentSelectionPolicy.conversationID(
      selectedConversationID: UUID(),
      currentDraftConversationIDs: [currentConversationID],
      fallbackConversationID: currentConversationID
    )
    let currentSelection = AIChatImageAttachmentSelectionPolicy.validSelection(
      surfaceState.imageAttachmentIDs(for: resolvedCurrentConversationID),
      availableAttachmentIDs: [currentAttachmentID]
    )
    surfaceState.setImageAttachmentIDs(currentSelection, for: resolvedCurrentConversationID)

    XCTAssertEqual(
      surfaceState.imageAttachmentIDs(for: currentConversationID), [currentAttachmentID])
    XCTAssertEqual(surfaceState.imageAttachmentIDs(for: otherConversationID), [otherAttachmentID])
  }
}
