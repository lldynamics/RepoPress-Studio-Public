import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DraftScopedPreflightSchedulingTests: XCTestCase {
  func testRunPreflightOnlyFlushesTheSelectedDraftBuffer() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftScopedPreflightSelected")
    let profile = store.activeProfile
    let firstDraft = makeDraft(
      profile: profile,
      title: "A draft",
      slug: "a-draft",
      body: "原始 A"
    )
    let secondDraft = makeDraft(
      profile: profile,
      title: "B draft",
      slug: "b-draft",
      body: "原始 B"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)

    let firstStage = try XCTUnwrap(
      store.stageDraftBody("已修改 A", for: firstDraft.id, baseRevision: 0)
    )
    let secondStage = try XCTUnwrap(
      store.stageDraftBody("已修改 B", for: secondDraft.id, baseRevision: 0)
    )
    XCTAssertTrue(firstStage.buffer.isDirty)
    XCTAssertTrue(secondStage.buffer.isDirty)

    store.runPreflight()

    XCTAssertFalse(store.draftBodyEditorBuffer(for: firstDraft.id).isDirty)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: secondDraft.id).isDirty)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == firstDraft.id })?.bodyMarkdown,
      "已修改 A"
    )
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == secondDraft.id })?.bodyMarkdown,
      "原始 B"
    )
  }

  func testDelayedRefreshForOldSelectionCannotOverwriteNewSelection() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftScopedPreflightSelection")
    let profile = store.activeProfile
    let firstDraft = makeDraft(
      profile: profile,
      title: "A draft",
      slug: "a-draft",
      body: "A"
    )
    let secondDraft = makeDraft(
      profile: profile,
      title: "B draft",
      slug: "b-draft",
      body: "B"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil

    let sentinel = PreflightIssue(
      severity: .warning,
      title: "B 当前检查",
      message: "旧 A 请求不得覆盖这个结果。"
    )
    store.setPreflightIssues([sentinel])
    store.schedulePreflightRefresh(for: firstDraft.id)

    try await Task.sleep(nanoseconds: 100_000_000)
    store.setSelectedDraftID(secondDraft.id)
    try await Task.sleep(nanoseconds: 750_000_000)

    XCTAssertEqual(store.selectedDraftID, secondDraft.id)
    XCTAssertEqual(store.preflightIssues, [sentinel])
  }

  func testNoArgumentRunPreflightAndWaitStillRefreshesCurrentDraft() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftScopedPreflightCurrent")
    let profile = store.activeProfile
    let firstDraft = makeDraft(
      profile: profile,
      title: "A draft",
      slug: "a-draft",
      body: "A"
    )
    let secondDraft = makeDraft(
      profile: profile,
      title: "B draft",
      slug: "b-draft",
      body: "原始 B"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(secondDraft.id)
    _ = try XCTUnwrap(
      store.stageDraftBody("已修改 B", for: secondDraft.id, baseRevision: 0)
    )

    await store.runPreflightAndWait()

    XCTAssertEqual(
      store.drafts.first(where: { $0.id == secondDraft.id })?.bodyMarkdown,
      "已修改 B"
    )
    XCTAssertNil(store.preflightRefreshTask)
  }

  private func makeDraft(
    profile: SiteProfile,
    title: String,
    slug: String,
    body: String
  ) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      slug: slug,
      bodyMarkdown: body
    )
  }
}
