import Combine
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIInlineStructuredEditReviewFacadeTests: XCTestCase {
  func testBeginReviewSelectsWritingSurfaceAndPublishesDraftScopedState() throws {
    let store = makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "行内审阅",
      slug: "inline-review",
      bodyMarkdown: "原文"
    )
    store.setDrafts([draft])
    store.selectDraft(draft.id)
    store.selectSection(.images)
    let document = AIStructuredEditDocument(changes: [
      AIStructuredEditProposal(
        id: "change-1",
        range: AIStructuredEditSourceRange(location: 0, length: 2),
        originalText: "原文",
        replacementText: "改文",
        reason: "测试",
        category: .clarity,
        confidence: 1
      )
    ])
    let payload = AIPublishingChatStructuredEditPayload(
      sourceDraftID: draft.id,
      sourceContentFingerprint: draft.repositoryContentFingerprint,
      goal: "校对",
      document: document
    )
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "结构化修改",
      structuredEditPayload: payload
    )

    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: message,
        review: AIStructuredEditReviewService.initialReview(for: document)
      ))
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.selectedDraft?.id, draft.id)
    XCTAssertEqual(store.editorFocusRequest?.draftID, draft.id)
    XCTAssertEqual(store.editorFocusRequest?.selectedRange, NSRange(location: 0, length: 2))
    XCTAssertEqual(
      store.ai.inlineStructuredEditReviewState.session(for: draft.id)?.draftID,
      draft.id
    )
    XCTAssertNotNil(store.ai.currentInlineStructuredEditReviewSession(for: draft.id))
  }

  func testReviewObservationDoesNotForwardUnrelatedStreamingChatChanges() {
    let store = makeStore()
    var reviewChanges = 0
    let cancellable = store.ai.inlineStructuredEditReviewState.objectWillChange.sink {
      reviewChanges += 1
    }

    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式 token")
    ])

    XCTAssertEqual(reviewChanges, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testMetadataMutationInvalidatesOpenReviewAtMutationBoundary() {
    let store = makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "行内审阅",
      slug: "inline-review",
      bodyMarkdown: "原文"
    )
    store.setDrafts([draft])
    let document = AIStructuredEditDocument(changes: [
      AIStructuredEditProposal(
        id: "change-1",
        range: AIStructuredEditSourceRange(location: 0, length: 2),
        originalText: "原文",
        replacementText: "改文",
        reason: "测试",
        category: .clarity,
        confidence: 1
      )
    ])
    let payload = AIPublishingChatStructuredEditPayload(
      sourceDraftID: draft.id,
      sourceContentFingerprint: draft.repositoryContentFingerprint,
      goal: "校对",
      document: document
    )
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "结构化修改",
      structuredEditPayload: payload
    )

    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: message,
        review: AIStructuredEditReviewService.initialReview(for: document)
      ))
    var renamed = draft
    renamed.title = "已改标题"
    store.updateDraft(renamed)

    XCTAssertNil(
      store.ai.validatedInlineStructuredEditReviewSession(
        for: renamed,
        body: renamed.bodyMarkdown
      ))
    XCTAssertNil(store.ai.inlineStructuredEditReviewState.session(for: draft.id))
  }

  func testDifferentDraftCannotInvalidateAnotherWindowsReview() {
    let store = makeStore()
    let reviewedDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "正在审阅",
      slug: "reviewed-draft",
      bodyMarkdown: "原文"
    )
    let otherDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "另一窗口",
      slug: "other-draft",
      bodyMarkdown: "另一篇正文"
    )
    store.setDrafts([reviewedDraft, otherDraft])
    let document = AIStructuredEditDocument(changes: [
      AIStructuredEditProposal(
        id: "change-1",
        range: AIStructuredEditSourceRange(location: 0, length: 2),
        originalText: "原文",
        replacementText: "改文",
        reason: "测试",
        category: .clarity,
        confidence: 1
      )
    ])
    let message = AIPublishingChatMessage(
      role: .assistant,
      content: "结构化修改",
      structuredEditPayload: AIPublishingChatStructuredEditPayload(
        sourceDraftID: reviewedDraft.id,
        sourceContentFingerprint: reviewedDraft.repositoryContentFingerprint,
        goal: "校对",
        document: document
      )
    )
    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: message,
        review: AIStructuredEditReviewService.initialReview(for: document)
      ))

    store.ai.invalidateInlineStructuredEditReviewIfStale(
      for: otherDraft,
      body: "另一窗口的未保存正文"
    )

    XCTAssertEqual(
      store.ai.inlineStructuredEditReviewState.session(for: reviewedDraft.id)?.draftID,
      reviewedDraft.id
    )
  }

  func testReviewsRemainIndependentAcrossDraftsAndEndingOnePreservesTheOther() {
    let store = makeStore()
    let first = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "窗口 A",
      slug: "window-a",
      bodyMarkdown: "甲文"
    )
    let second = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "窗口 B",
      slug: "window-b",
      bodyMarkdown: "乙文"
    )
    store.setDrafts([first, second])

    let firstDocument = AIStructuredEditDocument(changes: [
      AIStructuredEditProposal(
        id: "change-a",
        range: AIStructuredEditSourceRange(location: 0, length: 2),
        originalText: "甲文",
        replacementText: "甲改",
        reason: "测试",
        category: .clarity,
        confidence: 1
      )
    ])
    let secondDocument = AIStructuredEditDocument(changes: [
      AIStructuredEditProposal(
        id: "change-b",
        range: AIStructuredEditSourceRange(location: 0, length: 2),
        originalText: "乙文",
        replacementText: "乙改",
        reason: "测试",
        category: .clarity,
        confidence: 1
      )
    ])
    let firstMessage = structuredEditMessage(for: first, document: firstDocument)
    let secondMessage = structuredEditMessage(for: second, document: secondDocument)

    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: firstMessage,
        review: AIStructuredEditReviewService.initialReview(for: firstDocument)
      ))
    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: secondMessage,
        review: AIStructuredEditReviewService.initialReview(for: secondDocument)
      ))

    store.ai.setInlineStructuredEditDecision(
      .accepted,
      for: "change-a",
      draftID: first.id
    )
    XCTAssertEqual(
      store.ai.currentInlineStructuredEditReviewSession(for: first.id)?
        .review.decision(for: "change-a"),
      .accepted
    )
    XCTAssertEqual(
      store.ai.currentInlineStructuredEditReviewSession(for: second.id)?
        .review.decision(for: "change-b"),
      .pending
    )

    store.ai.endInlineStructuredEditReview(for: first.id)

    XCTAssertNil(store.ai.currentInlineStructuredEditReviewSession(for: first.id))
    XCTAssertNotNil(store.ai.currentInlineStructuredEditReviewSession(for: second.id))

    XCTAssertTrue(
      store.ai.beginInlineStructuredEditReview(
        message: firstMessage,
        review: AIStructuredEditReviewService.initialReview(for: firstDocument)
      ))
    store.ai.invalidateInlineStructuredEditReviewIfStale(
      for: first,
      body: "窗口 A 的新正文"
    )

    XCTAssertNil(store.ai.currentInlineStructuredEditReviewSession(for: first.id))
    XCTAssertNotNil(store.ai.currentInlineStructuredEditReviewSession(for: second.id))
  }

  private func structuredEditMessage(
    for draft: ArticleDraft,
    document: AIStructuredEditDocument
  ) -> AIPublishingChatMessage {
    AIPublishingChatMessage(
      role: .assistant,
      content: "结构化修改",
      structuredEditPayload: AIPublishingChatStructuredEditPayload(
        sourceDraftID: draft.id,
        sourceContentFingerprint: draft.repositoryContentFingerprint,
        goal: "校对",
        document: document
      )
    )
  }

  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-review-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: true
    )
  }
}
