import PublishingCoreSupport
import PublishingTestSupport
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceTaskInspectorIssuePresentationTests: XCTestCase {
  func testEditorQueryUsesRelatedValueForUnregisteredBodyImageRegardlessOfLocalizedCopy() {
    let issue = PreflightIssue(
      severity: .warning,
      title: "Arbitrary localized title",
      message: "Arbitrary localized message",
      field: "body",
      category: .unregisteredBodyImage,
      relatedValue: "/images/diagram.png"
    )

    XCTAssertEqual(issue.editorQuery, "/images/diagram.png")
  }

  func testEditorQueryRejectsRelatedValueFromOtherStructuredIssues() {
    let otherCategory = PreflightIssue(
      severity: .warning,
      title: "Arbitrary title",
      message: "Arbitrary message",
      field: "body",
      category: .publicRisk,
      relatedValue: "/images/diagram.png"
    )
    let otherField = PreflightIssue(
      severity: .warning,
      title: "Arbitrary title",
      message: "Arbitrary message",
      field: "attachments",
      category: .unregisteredBodyImage,
      relatedValue: "/images/diagram.png"
    )

    XCTAssertNil(otherCategory.editorQuery)
    XCTAssertNil(otherField.editorQuery)
  }

  func testIssueFocusTargetUsesStructuredFieldInsteadOfLocalizedCopy() {
    XCTAssertEqual(issue(field: "body").contentHealthFocusTargetTitle, "正文")
    XCTAssertEqual(issue(field: "summary").contentHealthFocusTargetTitle, "摘要")
    XCTAssertEqual(issue(field: "attachments").contentHealthFocusTargetTitle, "图片")
    XCTAssertEqual(issue(field: "title").contentHealthFocusTargetTitle, "元数据")
  }

  func testWritingContextPanelsAreExplicitlyEnumerated() {
    XCTAssertEqual(
      Set(MarkdownWritingContextPanel.allCases),
      Set([.selectionTools, .aiReview, .imageInfo, .outline])
    )
  }

  func testWritingInspectorUsesDedicatedKnowledgePage() {
    XCTAssertEqual(ArticleInspectorTab.defaultTab(for: .writing), .knowledge)
    XCTAssertEqual(
      ArticleInspectorTab.availableTabs(for: .writing),
      [.knowledge, .metadata, .seo, .images]
    )
    XCTAssertEqual(ArticleInspectorTab.knowledge.title, "上下文知识建议")
    XCTAssertEqual(ArticleInspectorTab.knowledge.pickerTitle, "知识建议")
    XCTAssertFalse(ArticleInspectorTab.availableTabs(for: .contentHealth).contains(.knowledge))
  }

  func testSummaryAIUnavailableReasonExplainsMissingAPIKey() {
    let availability = AIPublishingActionAvailabilityPresentation(
      isEnabled: false,
      unavailableReason: "需要先启用 AI"
    )

    XCTAssertEqual(
      WorkspaceTaskInspectorPresentation.summaryAIUnavailableReason(
        availability: availability,
        requiresAPIKey: true,
        hasAPIKey: false
      ),
      "未配置 API Key"
    )
  }

  func testSummaryAIUnavailableReasonPreservesContextRequirement() {
    let availability = AIPublishingActionAvailabilityPresentation(
      isEnabled: false,
      unavailableReason: "需要先补充标题、摘要或正文"
    )

    XCTAssertEqual(
      WorkspaceTaskInspectorPresentation.summaryAIUnavailableReason(
        availability: availability,
        requiresAPIKey: false,
        hasAPIKey: true
      ),
      "需要先补充标题、摘要或正文"
    )
  }

  func testSocialImagePresentationMarksSmallImagesWithoutBlockingThem() {
    let presentation = WorkspaceTaskInspectorPresentation.socialImagePresentation(
      imagePath: "images/cover.png",
      imageDimensions: ImageDimensions(width: 800, height: 600)
    )

    XCTAssertEqual(presentation.value, "800x600")
    XCTAssertEqual(presentation.warning, "尺寸偏小，建议至少 1200×630")
  }

  func testSocialImagePresentationDoesNotWarnForRecommendedDimensions() {
    let presentation = WorkspaceTaskInspectorPresentation.socialImagePresentation(
      imagePath: "images/cover.png",
      imageDimensions: ImageDimensions(width: 1200, height: 630)
    )

    XCTAssertNil(presentation.warning)
  }

  func testSEOCharacterCountUsesTheSameUnitAcrossInspectorSurfaces() {
    XCTAssertEqual(WorkspaceTaskInspectorPresentation.seoCharacterCountText(8), "8 字符")
  }

  private func issue(field: String) -> PreflightIssue {
    PreflightIssue(
      severity: .warning,
      title: "标题",
      message: "消息",
      field: field
    )
  }
}

@MainActor
extension WorkspaceTaskInspectorIssuePresentationTests {
  func testPreflightModelRejectsOutOfOrderResult() async {
    let model = ArticleInspectorPreflightModel()
    let firstKey = makePreflightKey()
    let secondKey = makePreflightKey()
    let firstGate = AsyncGate()
    let secondGate = AsyncGate()
    let firstResult = makePreflightResult(draftID: UUID())
    let secondDraftID = UUID()
    let secondResult = makePreflightResult(draftID: secondDraftID)

    let firstTask = Task { @MainActor in
      await model.refresh(requestKey: firstKey, draftID: firstResult.context.draftID) {
        await firstGate.waitUntilOpen()
        return firstResult
      }
    }
    await firstGate.waitUntilWaiting()
    let secondTask = Task { @MainActor in
      await model.refresh(requestKey: secondKey, draftID: secondDraftID) {
        await secondGate.waitUntilOpen()
        return secondResult
      }
    }
    await secondGate.waitUntilWaiting()
    await secondGate.open()
    await secondTask.value
    await firstGate.open()
    await firstTask.value

    XCTAssertEqual(model.result, secondResult)
    XCTAssertEqual(model.requestKey, secondKey)
  }

  func testPreflightModelCancellationAndNilDoNotLookLikePass() async {
    let model = ArticleInspectorPreflightModel()
    let key = makePreflightKey()
    let gate = AsyncGate()
    let draftID = UUID()
    let task = Task { @MainActor in
      await model.refresh(requestKey: key, draftID: draftID) {
        await gate.waitUntilOpen()
        return nil
      }
    }
    await gate.waitUntilWaiting()
    task.cancel()
    await gate.open()
    await task.value
    XCTAssertEqual(model.state, .loading)
    XCTAssertNil(model.result)

    await model.refresh(requestKey: key, draftID: draftID) { nil }
    XCTAssertEqual(model.state, .unavailable)
    XCTAssertNil(model.result)
  }

  func testPreflightModelKeepsPreviousResultVisibleDuringDebouncedRefresh() async {
    let clock = ManualClock()
    let model = ArticleInspectorPreflightModel(clock: clock)
    let draftID = UUID()
    let initialResult = makePreflightResult(draftID: draftID)
    await model.refresh(requestKey: makePreflightKey(), draftID: draftID) { initialResult }

    let nextKey = makePreflightKey()
    let refreshedResult = makePreflightResult(draftID: draftID)
    let refreshTask = Task { @MainActor in
      await model.refresh(
        requestKey: nextKey,
        draftID: draftID,
        debounceDuration: DebounceIntervals.preflightRefresh
      ) { refreshedResult }
    }

    await clock.waitForSleepCount(1)
    XCTAssertEqual(model.state, .loading)
    XCTAssertEqual(model.result, initialResult)

    clock.advance(by: DebounceIntervals.preflightRefresh)
    await refreshTask.value
    XCTAssertEqual(model.state, .available)
    XCTAssertEqual(model.result, refreshedResult)
  }

  func testPreflightModelMarksRetainedResultUnavailableWhenRefreshFails() async {
    let model = ArticleInspectorPreflightModel()
    let draftID = UUID()
    let initialResult = makePreflightResult(draftID: draftID)
    await model.refresh(requestKey: makePreflightKey(), draftID: draftID) { initialResult }

    await model.refresh(requestKey: makePreflightKey(), draftID: draftID) { nil }

    XCTAssertEqual(model.state, .unavailable)
    XCTAssertEqual(model.result, initialResult)
  }

  func testPreflightModelRejectsWrongArticleAndRetriesSameKey() async {
    let model = ArticleInspectorPreflightModel()
    let key = makePreflightKey()
    let draftID = UUID()
    await model.refresh(requestKey: key, draftID: draftID) {
      self.makePreflightResult(draftID: UUID())
    }
    XCTAssertEqual(model.state, .unavailable)

    let result = makePreflightResult(draftID: draftID)
    await model.refresh(requestKey: key, draftID: draftID) { result }
    XCTAssertEqual(model.result, result)
    XCTAssertEqual(model.state, .available)
  }

  private func makePreflightKey() -> DraftScopedPreflightRequestKey {
    DraftScopedPreflightRequestKey(
      draftID: UUID(), bodyRevision: 1, hasPendingBody: false,
      draftMutationRevision: 1, linkAuditInputGeneration: 1,
      profile: SiteProfile(name: "Test"), repositoryReportRevision: UUID()
    )
  }

  private func makePreflightResult(draftID: UUID) -> DraftPreflightResult {
    DraftPreflightResult(
      context: DraftExecutionContext(draftID: draftID, profileID: UUID(), bodyRevision: 1),
      issues: []
    )
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var waiting = false
  private var waitingContinuation: CheckedContinuation<Void, Never>?

  func waitUntilOpen() async {
    waiting = true
    waitingContinuation?.resume()
    waitingContinuation = nil
    if isOpen { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func waitUntilWaiting() async {
    if waiting { return }
    await withCheckedContinuation { waitingContinuation = $0 }
  }

  func open() {
    isOpen = true
    waiter?.resume()
    waiter = nil
    waitingContinuation?.resume()
    waitingContinuation = nil
  }
}
