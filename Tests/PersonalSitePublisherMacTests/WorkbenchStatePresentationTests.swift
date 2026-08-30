import XCTest
@testable import PersonalSitePublisherMac

final class WorkbenchStatePresentationTests: XCTestCase {
  func testCoreKindsUseCanonicalTitlesSymbolsAndTones() {
    let fixtures: [(WorkbenchStateKind, String, String, WorkbenchStateTone)] = [
      (.loading(), "正在加载", "arrow.triangle.2.circlepath", .progress),
      (.empty, "暂无内容", "tray", .neutral),
      (.success(detail: "done"), "已完成", "checkmark.circle", .success),
      (.failure(reason: "network"), "失败", "xmark.octagon", .risk),
      (
        .partialSuccess(detail: "one item needs review"),
        "部分完成",
        "exclamationmark.triangle",
        .warning
      ),
      (
        .awaitingConfirmation(detail: "review before continuing"),
        "等待确认",
        "hand.raised",
        .warning
      ),
      (.unavailable(reason: "missing profile"), "当前操作暂不可用", "nosign", .warning),
    ]

    for (kind, title, systemImage, tone) in fixtures {
      XCTAssertEqual(kind.titleKey, title)
      XCTAssertEqual(kind.defaultSystemImage, systemImage)
      XCTAssertEqual(kind.tone, tone)
    }
  }

  func testOnlyLoadingExposesClampedProgress() {
    XCTAssertNil(WorkbenchStateKind.loading().loadingProgress)
    XCTAssertEqual(WorkbenchStateKind.loading(progress: -0.2).loadingProgress, 0)
    XCTAssertEqual(WorkbenchStateKind.loading(progress: 0.4).loadingProgress, 0.4)
    XCTAssertEqual(WorkbenchStateKind.loading(progress: 1.4).loadingProgress, 1)
    XCTAssertEqual(WorkbenchStateKind.loading(progress: .nan).loadingProgress, 0)
    XCTAssertNil(WorkbenchStateKind.empty.loadingProgress)
    XCTAssertNil(WorkbenchStateKind.failure(reason: "x").loadingProgress)
  }

  func testFailureAndUnavailableFormatTrimmedReasons() {
    let failure = WorkbenchStatePresentation(kind: .failure(reason: "  网络已断开\n"))
    let unavailable = WorkbenchStatePresentation(kind: .unavailable(reason: "  未选择站点  "))

    XCTAssertEqual(failure.kind.reason, "网络已断开")
    XCTAssertEqual(unavailable.kind.reason, "未选择站点")
    XCTAssertTrue(failure.formattedReason?.contains("网络已断开") == true)
    XCTAssertTrue(unavailable.formattedReason?.contains("未选择站点") == true)
    XCTAssertNil(WorkbenchStatePresentation(kind: .failure(reason: "  ")).formattedReason)
  }

  func testReasonFormattingRemovesExistingCanonicalPrefixes() {
    let plain = WorkbenchStatePresentation(kind: .failure(reason: "网络已断开"))
    let failurePrefixed = WorkbenchStatePresentation(kind: .failure(reason: "失败：网络已断开"))
    let reasonPrefixed = WorkbenchStatePresentation(kind: .failure(reason: "原因：网络已断开"))
    let asciiReasonPrefixed = WorkbenchStatePresentation(kind: .failure(reason: "原因:网络已断开"))
    let repeatedPrefixes = WorkbenchStatePresentation(
      kind: .failure(reason: "失败：原因：网络已断开")
    )

    XCTAssertEqual(failurePrefixed.formattedReason, plain.formattedReason)
    XCTAssertEqual(reasonPrefixed.formattedReason, plain.formattedReason)
    XCTAssertEqual(asciiReasonPrefixed.formattedReason, plain.formattedReason)
    XCTAssertEqual(repeatedPrefixes.formattedReason, plain.formattedReason)
  }

  func testPartialSuccessAndConfirmationUseDetailInsteadOfReasonCopy() {
    let partial = WorkbenchStatePresentation(
      kind: .partialSuccess(detail: "  已处理 3 项；1 项需复核。  ")
    )
    let confirmation = WorkbenchStatePresentation(
      kind: .awaitingConfirmation(detail: "  尚未写入，确认后继续。  ")
    )

    XCTAssertNil(partial.formattedReason)
    XCTAssertEqual(partial.verbatimDetail, "已处理 3 项；1 项需复核。")
    XCTAssertNil(confirmation.formattedReason)
    XCTAssertEqual(confirmation.verbatimDetail, "尚未写入，确认后继续。")
  }

  func testAnnouncementIdentityIncludesSemanticKind() {
    let failure = WorkbenchStatePresentation(kind: .failure(reason: "same"))
    let unavailable = WorkbenchStatePresentation(kind: .unavailable(reason: "same"))

    XCTAssertNotEqual(failure.announcementIdentity, unavailable.announcementIdentity)
    guard case .error = failure.announcementSeverity else {
      return XCTFail("Failure states must use error announcements.")
    }
    guard case .warning = unavailable.announcementSeverity else {
      return XCTFail("Unavailable states must use warning announcements.")
    }
  }

  func testAnnouncementsAreOptInAndNeverMoveFocus() {
    let silent = WorkbenchStatePresentation(kind: .empty)
    let announced = WorkbenchStatePresentation(
      kind: .partialSuccess(detail: "needs review"),
      announcementPolicy: .announce
    )

    XCTAssertFalse(silent.announcementPolicy.shouldAnnounce)
    XCTAssertTrue(announced.announcementPolicy.shouldAnnounce)
    XCTAssertFalse(announced.announcementPolicy.shouldMoveAccessibilityFocus)
  }

  func testPresentationCanOverrideOnlyTheSymbol() {
    let presentation = WorkbenchStatePresentation(
      kind: .empty,
      icon: "doc.text.magnifyingglass"
    )

    XCTAssertEqual(presentation.titleKey, "暂无内容")
    XCTAssertEqual(presentation.systemImage, "doc.text.magnifyingglass")
  }

  func testStateActionsDefaultToEnabledAndCanPreserveDisabledActions() {
    let enabled = WorkbenchStateAction(title: "重试", action: {})
    let disabled = WorkbenchStateAction(title: "搜索全部站点", isEnabled: false, action: {})

    XCTAssertTrue(enabled.isEnabled)
    XCTAssertFalse(disabled.isEnabled)
  }
}
