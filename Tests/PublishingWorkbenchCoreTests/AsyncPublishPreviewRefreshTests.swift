import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class AsyncPublishPreviewRefreshTests: XCTestCase {
  func testBackgroundRefreshMatchesSynchronousPublishingState() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "AsyncPublishPreviewRefresh")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    var profile = store.activeProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Background Preview",
      slug: "background-preview",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough to exercise background publishing preview refresh."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshPublishPreview(for: draft)

    let expectedPackage = try XCTUnwrap(store.publishPackage)
    let expectedPreview = try XCTUnwrap(store.localPublishPreview)
    let expectedReadiness = try XCTUnwrap(store.localPublishReadiness)
    let expectedRemote = try XCTUnwrap(store.remotePublishPreviewSnapshot)

    store.refreshPublishPreviewInBackground(for: draft)
    XCTAssertTrue(store.isPublishPreviewRefreshing)
    await store.publishingStore.waitForPublishPreviewRefresh()

    XCTAssertFalse(store.isPublishPreviewRefreshing)
    assertEquivalent(try XCTUnwrap(store.publishPackage), expectedPackage)
    assertEquivalent(try XCTUnwrap(store.localPublishPreview), expectedPreview)
    assertEquivalent(try XCTUnwrap(store.localPublishReadiness), expectedReadiness)
    assertEquivalent(try XCTUnwrap(store.remotePublishPreviewSnapshot), expectedRemote)
  }

  func testOlderBackgroundPreviewCannotReplaceNewerDraftPreview() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "First Preview",
      slug: "first-preview",
      draft: false,
      bodyMarkdown: "This first body is intentionally long enough for a valid publishing package."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second Preview",
      slug: "second-preview",
      draft: false,
      bodyMarkdown: "This second body is intentionally long enough for a valid publishing package."
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)

    let gate = AsyncPublishPreviewGate()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      if package.draftID == firstDraft.id {
        await gate.suspendFirstPreview()
      }
      return LocalPublishPreview(
        package: package,
        fileDiffs: [
          PublishFileDiff(
            path: package.markdownPath,
            kind: .markdown,
            status: .added,
            byteSize: Int64(package.markdownFile?.content?.utf8.count ?? 0)
          ),
        ],
        issues: [],
        generatedAt: Date(timeIntervalSince1970: package.draftID == firstDraft.id ? 1 : 2)
      )
    }

    store.publishingStore.schedulePublishPreviewRefresh(
      for: firstDraft,
      store: store,
      previewProvider: provider
    )
    let firstTask = store.publishingStore.publishPreviewRefreshTask
    await gate.waitUntilFirstPreviewStarts()

    store.setSelectedDraftID(secondDraft.id)
    store.publishingStore.schedulePublishPreviewRefresh(
      for: secondDraft,
      store: store,
      previewProvider: provider
    )
    await store.publishingStore.waitForPublishPreviewRefresh()

    XCTAssertEqual(store.publishPackage?.draftID, secondDraft.id)
    XCTAssertEqual(store.localPublishPreview?.generatedAt, Date(timeIntervalSince1970: 2))

    await gate.releaseFirstPreview()
    await firstTask?.value

    XCTAssertEqual(store.publishPackage?.draftID, secondDraft.id)
    XCTAssertEqual(store.localPublishPreview?.generatedAt, Date(timeIntervalSince1970: 2))
  }

  func testExplicitNonSelectedDraftCannotReplaceSharedPreviewState() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let selectedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selected Preview",
      slug: "selected-preview",
      draft: false,
      bodyMarkdown: "The selected article remains the owner of shared preview state."
    )
    let otherDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Other Preview",
      slug: "other-preview",
      draft: false,
      bodyMarkdown: "A non-selected article must not replace shared preview state."
    )
    store.setDrafts([selectedDraft, otherDraft])
    store.setSelectedDraftID(selectedDraft.id)
    store.refreshPublishPreview(for: selectedDraft)
    let originalPackage = try XCTUnwrap(store.publishPackage)

    let invocation = AsyncPublishPreviewInvocation()
    store.publishingStore.schedulePublishPreviewRefresh(
      for: otherDraft,
      store: store,
      previewProvider: { package, _ in
        await invocation.record(package.draftID)
        return LocalPublishPreview(package: package, fileDiffs: [], issues: [])
      }
    )
    await store.publishingStore.waitForPublishPreviewRefresh()

    XCTAssertEqual(store.publishPackage?.draftID, originalPackage.draftID)
    let invokedDraftIDs = await invocation.draftIDs()
    XCTAssertEqual(invokedDraftIDs, [])
    XCTAssertFalse(store.isPublishPreviewRefreshing)
  }

  private func assertEquivalent(_ actual: LocalPublishPreview, _ expected: LocalPublishPreview) {
    assertEquivalent(actual.package, expected.package)
    XCTAssertEqual(actual.fileDiffs, expected.fileDiffs)
    XCTAssertEqual(issueSignatures(actual.issues), issueSignatures(expected.issues))
  }

  private func assertEquivalent(_ actual: PublishPackage, _ expected: PublishPackage) {
    XCTAssertEqual(actual.draftID, expected.draftID)
    XCTAssertEqual(actual.title, expected.title)
    XCTAssertEqual(actual.draftSummary, expected.draftSummary)
    XCTAssertEqual(actual.draftCoverAltText, expected.draftCoverAltText)
    XCTAssertEqual(actual.markdownPath, expected.markdownPath)
    XCTAssertEqual(actual.files, expected.files)
    XCTAssertEqual(actual.commitMessage, expected.commitMessage)
    XCTAssertEqual(actual.reviewBranchName, expected.reviewBranchName)
    XCTAssertEqual(actual.reviewTitle, expected.reviewTitle)
    XCTAssertEqual(actual.reviewChecklist, expected.reviewChecklist)
  }

  private func assertEquivalent(_ actual: LocalPublishReadiness, _ expected: LocalPublishReadiness) {
    XCTAssertEqual(actual.writeReadiness, expected.writeReadiness)
    XCTAssertEqual(actual.commitReadiness, expected.commitReadiness)
    XCTAssertEqual(actual.changedFileCount, expected.changedFileCount)
    XCTAssertEqual(actual.fileCount, expected.fileCount)
    XCTAssertEqual(issueSignatures(actual.writeBlockingIssues), issueSignatures(expected.writeBlockingIssues))
    XCTAssertEqual(issueSignatures(actual.commitBlockingIssues), issueSignatures(expected.commitBlockingIssues))
    XCTAssertEqual(issueSignatures(actual.warningIssues), issueSignatures(expected.warningIssues))
  }

  private func assertEquivalent(
    _ actual: RemoteRepositoryPublishPreview,
    _ expected: RemoteRepositoryPublishPreview
  ) {
    XCTAssertEqual(actual.provider, expected.provider)
    XCTAssertEqual(actual.repositoryName, expected.repositoryName)
    XCTAssertEqual(actual.mode, expected.mode)
    XCTAssertEqual(actual.branchName, expected.branchName)
    XCTAssertEqual(actual.targetBranch, expected.targetBranch)
    XCTAssertEqual(actual.changedPaths, expected.changedPaths)
    XCTAssertEqual(actual.remoteConflictPaths, expected.remoteConflictPaths)
    XCTAssertEqual(actual.remoteRiskState, expected.remoteRiskState)
    XCTAssertEqual(actual.hasToken, expected.hasToken)
    XCTAssertEqual(actual.accessCheck, expected.accessCheck)
    XCTAssertEqual(issueSignatures(actual.blockingIssues), issueSignatures(expected.blockingIssues))
    XCTAssertEqual(issueSignatures(actual.warningIssues), issueSignatures(expected.warningIssues))
  }

  private func issueSignatures(_ issues: [PreflightIssue]) -> [String] {
    issues.map { issue in
      "\(issue.severity)|\(issue.title)|\(issue.message)|\(issue.field ?? "")"
    }
  }
}

private actor AsyncPublishPreviewInvocation {
  private var recordedDraftIDs: [UUID] = []

  func record(_ draftID: UUID) {
    recordedDraftIDs.append(draftID)
  }

  func draftIDs() -> [UUID] {
    recordedDraftIDs
  }
}

private actor AsyncPublishPreviewGate {
  private var didStartFirstPreview = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspendFirstPreview() async {
    didStartFirstPreview = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilFirstPreviewStarts() async {
    guard !didStartFirstPreview else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseFirstPreview() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
