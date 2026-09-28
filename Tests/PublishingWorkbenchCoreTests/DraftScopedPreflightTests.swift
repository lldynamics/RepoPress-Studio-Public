import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftScopedPreflightTests: XCTestCase {
  func testNonSelectedDraftCanBeCheckedWithoutChangingSelectionOrGlobalIssues() async throws {
    let store = try makeSafeStore(prefix: "DraftScopedPreflightSelection")
    let selectedDraft = try XCTUnwrap(store.selectedDraft)
    let targetDraft = try addSiteDraft(to: store)
    store.selectDraft(selectedDraft.id)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil

    let globalIssue = PreflightIssue(
      severity: .warning,
      title: "全局状态保留",
      message: "draft-scoped preflight 不应写入这里。",
      field: "test"
    )
    store.publishingStore.preflightIssues = [globalIssue]
    let selectedDraftID = try XCTUnwrap(store.selectedDraftID)

    let result = await store.runPreflight(for: targetDraft.id)

    XCTAssertNotNil(result)
    XCTAssertEqual(store.selectedDraftID, selectedDraftID)
    XCTAssertEqual(store.preflightIssues, [globalIssue])
  }

  func testOnlyTargetEditorBufferIsFlushed() async throws {
    let store = try makeSafeStore(prefix: "DraftScopedPreflightBuffer")
    let firstDraft = try XCTUnwrap(store.selectedDraft)
    let secondDraft = try addSiteDraft(to: store)
    store.selectDraft(firstDraft.id)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil

    let firstBody = "主窗口仍在输入的正文"
    let secondBody = String(repeating: "目标草稿正文 ", count: 20)
    let firstRevision = store.draftBodyEditorBuffer(for: firstDraft.id).revision
    let secondRevision = store.draftBodyEditorBuffer(for: secondDraft.id).revision
    _ = store.stageDraftBody(firstBody, for: firstDraft.id, baseRevision: firstRevision)
    _ = store.stageDraftBody(secondBody, for: secondDraft.id, baseRevision: secondRevision)
    store.draftBodyCommitTasks[firstDraft.id]?.cancel()
    store.draftBodyCommitTasks[firstDraft.id] = nil

    let result = await store.runPreflight(for: secondDraft.id)

    XCTAssertNotNil(result)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == secondDraft.id })?.bodyMarkdown,
      secondBody
    )
    XCTAssertFalse(store.draftBodyEditorBuffer(for: secondDraft.id).isDirty)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == firstDraft.id })?.bodyMarkdown,
      firstDraft.bodyMarkdown
    )
    XCTAssertTrue(store.draftBodyEditorBuffer(for: firstDraft.id).isDirty)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: firstDraft.id).bodyMarkdown, firstBody)
  }

  func testResultContextIdentifiesDraftProfileAndFlushedBodyRevision() async throws {
    let store = try makeSafeStore(prefix: "DraftScopedPreflightContext")
    let draft = try XCTUnwrap(store.selectedDraft)
    let body = String(repeating: "带有稳定上下文的正文 ", count: 20)
    let initialRevision = store.draftBodyEditorBuffer(for: draft.id).revision
    _ = store.stageDraftBody(body, for: draft.id, baseRevision: initialRevision)
    store.draftBodyCommitTasks[draft.id]?.cancel()
    store.draftBodyCommitTasks[draft.id] = nil

    let pendingResult = await store.runPreflight(for: draft.id)
    let result = try XCTUnwrap(pendingResult)
    let currentBuffer = store.draftBodyEditorBuffer(for: draft.id)

    XCTAssertEqual(result.context.draftID, draft.id)
    XCTAssertEqual(result.context.profileID, store.profile(for: draft).id)
    XCTAssertEqual(result.context.bodyRevision, currentBuffer.revision)
    XCTAssertFalse(currentBuffer.isDirty)
  }

  func testGeneralDraftReturnsTheExistingPublishingIssue() async throws {
    let store = try makeSafeStore(prefix: "DraftScopedPreflightGeneral")
    let generalDraft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.updateDraft(generalDraft)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil

    let pendingResult = await store.runPreflight(for: generalDraft.id)
    let result = try XCTUnwrap(pendingResult)

    let expected = store.publishingStore.generalDraftPublishingIssue
    XCTAssertEqual(result.issues.count, 1)
    XCTAssertEqual(result.issues.first?.severity, expected.severity)
    XCTAssertEqual(result.issues.first?.title, expected.title)
    XCTAssertEqual(result.issues.first?.message, expected.message)
    XCTAssertEqual(result.issues.first?.field, expected.field)
  }

  private func makeSafeStore(prefix: String) throws -> WorkbenchStore {
    WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: prefix),
      safeMode: true
    )
  }

  private func addSiteDraft(to store: WorkbenchStore) throws -> ArticleDraft {
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "第二篇草稿",
      slug: "second-draft-(UUID().uuidString.lowercased())",
      bodyMarkdown: String(repeating: "第二篇草稿正文 ", count: 20)
    )
    store.updateDraft(draft)
    return try XCTUnwrap(store.drafts.first(where: { $0.id == draft.id }))
  }
}

@MainActor
final class DraftScopedPreflightRequestKeyTests: XCTestCase {
  func testRepeatedReadsAndAnotherWindowsSelectionKeepTheSameKey() throws {
    let store = try makeStore()
    let first = try XCTUnwrap(store.drafts.first)
    let second = ArticleDraft(siteProfileID: store.activeProfileID, title: "Second", slug: "second")
    store.updateDraft(second)
    let key = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: first.id))

    store.selectDraft(second.id)

    XCTAssertEqual(store.draftScopedPreflightRequestKey(for: first.id), key)
    XCTAssertNil(store.draftScopedPreflightRequestKey(for: UUID()))
  }

  func testPendingBodyAndSiblingChangesInvalidateTheWindowRequest() throws {
    let store = try makeStore()
    let first = try XCTUnwrap(store.drafts.first)
    var second = ArticleDraft(siteProfileID: store.activeProfileID, title: "Second", slug: "second")
    store.updateDraft(second)
    let initial = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: first.id))
    let buffer = store.draftBodyEditorBuffer(for: first.id)

    _ = store.stageDraftBody("Pending body", for: first.id, baseRevision: buffer.revision)
    let pending = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: first.id))
    XCTAssertNotEqual(initial, pending)

    second.slug = first.slug
    store.updateDraft(second)
    XCTAssertNotEqual(store.draftScopedPreflightRequestKey(for: first.id), pending)
  }

  func testProfileAndRepositoryInvalidationRefreshTheRequest() throws {
    let store = try makeStore()
    let draft = try XCTUnwrap(store.drafts.first)
    let initial = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: draft.id))

    store.updateActiveProfile { $0.siteKind = .hugo }
    let changedProfile = try XCTUnwrap(store.draftScopedPreflightRequestKey(for: draft.id))
    XCTAssertNotEqual(initial, changedProfile)

    store.setRepositoryReport(nil)
    XCTAssertNotEqual(store.draftScopedPreflightRequestKey(for: draft.id), changedProfile)
  }

  func testRepositoryReportRevisionIsTheOnlyRepositoryRequestInput() {
    let profile = SiteProfile(name: "Test")
    let repositoryReportRevision = UUID()
    let first = DraftScopedPreflightRequestKey(
      draftID: UUID(), bodyRevision: 1, hasPendingBody: false,
      draftMutationRevision: 1, linkAuditInputGeneration: 1,
      profile: profile, repositoryReportRevision: repositoryReportRevision
    )
    let second = DraftScopedPreflightRequestKey(
      draftID: first.draftID, bodyRevision: first.bodyRevision,
      hasPendingBody: first.hasPendingBody,
      draftMutationRevision: first.draftMutationRevision,
      linkAuditInputGeneration: first.linkAuditInputGeneration,
      profile: first.profile, repositoryReportRevision: repositoryReportRevision
    )

    XCTAssertEqual(first, second)
  }

  private func makeStore() throws -> WorkbenchStore {
    let persistence = try TestWorkbenchFactory.persistence(prefix: "DraftPreflightRequestKey")
    let rootURL = persistence.fileURL.deletingLastPathComponent()
    addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(persistence: persistence, safeMode: true)
    store.updateDraft(
      ArticleDraft(siteProfileID: store.activeProfileID, title: "First", slug: "first")
    )
    return store
  }
}
