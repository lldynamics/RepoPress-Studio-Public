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
    let refreshedSnapshot = await store.refreshPublishPreview(for: draft.id)
    let expectedSnapshot = try XCTUnwrap(refreshedSnapshot)

    store.refreshPublishPreviewInBackground(for: draft.id)
    XCTAssertTrue(store.isPublishPreviewRefreshing(for: draft.id))
    await store.waitForPublishPreviewRefresh(for: draft.id)

    XCTAssertFalse(store.isPublishPreviewRefreshing(for: draft.id))
    let actualSnapshot = try XCTUnwrap(store.cachedPublishPreview(for: draft.id))
    assertEquivalent(actualSnapshot, expectedSnapshot)
  }

  func testSameDraftOlderGenerationCannotReplaceNewerPreview() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Generation Preview",
      slug: "generation-preview",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for generation ordering coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let gate = AsyncPublishPreviewGate()
    let invocation = AsyncPublishPreviewInvocation()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      let invocationNumber = await invocation.recordAndReturn(package.draftID)
      if invocationNumber == 1 {
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
        generatedAt: Date(timeIntervalSince1970: TimeInterval(invocationNumber))
      )
    }

    store.publishingStore.schedulePublishPreviewRefresh(
      for: draft.id,
      store: store,
      previewProvider: provider
    )
    let firstTask = store.publishingStore.publishPreviewRefreshTask
    await gate.waitUntilFirstPreviewStarts()

    store.publishingStore.schedulePublishPreviewRefresh(
      for: draft.id,
      store: store,
      previewProvider: provider
    )
    await store.waitForPublishPreviewRefresh(for: draft.id)

    let newerSnapshot = try XCTUnwrap(store.cachedPublishPreview(for: draft.id))
    XCTAssertEqual(newerSnapshot.context.draftID, draft.id)
    XCTAssertEqual(newerSnapshot.localPublishPreview.generatedAt, Date(timeIntervalSince1970: 2))

    await gate.releaseFirstPreview()
    await firstTask?.value

    let finalSnapshot = try XCTUnwrap(store.cachedPublishPreview(for: draft.id))
    XCTAssertEqual(finalSnapshot.localPublishPreview.generatedAt, Date(timeIntervalSince1970: 2))
    let generationInvocationIDs = await invocation.draftIDs()
    XCTAssertEqual(generationInvocationIDs, [draft.id, draft.id])
  }

  func testNonSelectedDraftRefreshUsesOwnCacheAndDoesNotDriveSelectedSpinner() async throws {
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
    let originalProfileID = store.activeProfileID
    let originalPackage = store.publishPackage
    let originalPreview = store.localPublishPreview
    let originalReadiness = store.localPublishReadiness
    let originalRemote = store.remotePublishPreviewSnapshot
    let originalReviewDraft = store.remoteReviewDraft

    let invocation = AsyncPublishPreviewInvocation()
    store.publishingStore.schedulePublishPreviewRefresh(
      for: otherDraft.id,
      store: store,
      previewProvider: { package, _ in
        await invocation.record(package.draftID)
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
          issues: []
        )
      }
    )
    XCTAssertTrue(store.isPublishPreviewRefreshing(for: otherDraft.id))
    XCTAssertFalse(store.isPublishPreviewRefreshing(for: selectedDraft.id))
    XCTAssertFalse(store.isPublishPreviewRefreshing)
    await store.waitForPublishPreviewRefresh(for: otherDraft.id)

    let cachedOther = try XCTUnwrap(store.cachedPublishPreview(for: otherDraft.id))
    XCTAssertEqual(cachedOther.context.draftID, otherDraft.id)
    XCTAssertEqual(cachedOther.publishPackage.draftID, otherDraft.id)
    XCTAssertEqual(cachedOther.localPublishPreview.package.draftID, otherDraft.id)
    let invocationDraftIDs = await invocation.draftIDs()
    XCTAssertEqual(invocationDraftIDs, [otherDraft.id])
    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertEqual(store.publishPackage, originalPackage)
    XCTAssertEqual(store.localPublishPreview, originalPreview)
    XCTAssertEqual(store.localPublishReadiness, originalReadiness)
    XCTAssertEqual(store.remotePublishPreviewSnapshot, originalRemote)
    XCTAssertEqual(store.remoteReviewDraft, originalReviewDraft)
    XCTAssertFalse(store.isPublishPreviewRefreshing)
  }

  func testDifferentDraftRefreshesRunInParallelWithoutCancellingEachOther() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let draftA = ArticleDraft(
      siteProfileID: profile.id,
      title: "Parallel A",
      slug: "parallel-a",
      draft: false,
      bodyMarkdown: "The first parallel preview has enough content for a valid package."
    )
    let draftB = ArticleDraft(
      siteProfileID: profile.id,
      title: "Parallel B",
      slug: "parallel-b",
      draft: false,
      bodyMarkdown: "The second parallel preview has enough content for a valid package."
    )
    store.setDrafts([draftA, draftB])
    store.setSelectedDraftID(draftA.id)

    let gateA = AsyncPublishPreviewGate()
    let gateB = AsyncPublishPreviewGate()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      if package.draftID == draftA.id {
        await gateA.suspendFirstPreview()
      } else {
        await gateB.suspendFirstPreview()
      }
      return LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    }

    store.publishingStore.schedulePublishPreviewRefresh(
      for: draftA.id,
      store: store,
      previewProvider: provider
    )
    store.publishingStore.schedulePublishPreviewRefresh(
      for: draftB.id,
      store: store,
      previewProvider: provider
    )

    await gateA.waitUntilFirstPreviewStarts()
    await gateB.waitUntilFirstPreviewStarts()
    XCTAssertTrue(store.isPublishPreviewRefreshing(for: draftA.id))
    XCTAssertTrue(store.isPublishPreviewRefreshing(for: draftB.id))

    await gateA.releaseFirstPreview()
    await gateB.releaseFirstPreview()
    await store.waitForPublishPreviewRefresh(for: draftA.id)
    await store.waitForPublishPreviewRefresh(for: draftB.id)

    XCTAssertEqual(store.cachedPublishPreview(for: draftA.id)?.context.draftID, draftA.id)
    XCTAssertEqual(store.cachedPublishPreview(for: draftB.id)?.context.draftID, draftB.id)
    XCTAssertFalse(store.isPublishPreviewRefreshing(for: draftA.id))
    XCTAssertFalse(store.isPublishPreviewRefreshing(for: draftB.id))
  }

  func testSelectionChangeDoesNotProjectRefreshingDraftIntoNewSelection() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let draftA = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection A",
      slug: "selection-a",
      draft: false,
      bodyMarkdown: "The first selection preview has enough content for a valid package."
    )
    let draftB = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selection B",
      slug: "selection-b",
      draft: false,
      bodyMarkdown: "The second selection preview has enough content for a valid package."
    )
    store.setDrafts([draftA, draftB])
    store.setSelectedDraftID(draftB.id)
    store.refreshPublishPreview(for: draftB)
    let originalBPackage = try XCTUnwrap(store.publishPackage)
    let originalBPreview = try XCTUnwrap(store.localPublishPreview)
    let originalBReadiness = try XCTUnwrap(store.localPublishReadiness)
    let originalBRemote = try XCTUnwrap(store.remotePublishPreviewSnapshot)
    let originalBReviewDraft = try XCTUnwrap(store.remoteReviewDraft)

    store.setSelectedDraftID(draftA.id)
    let gate = AsyncPublishPreviewGate()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      await gate.suspendFirstPreview()
      return LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    }
    store.publishingStore.schedulePublishPreviewRefresh(
      for: draftA.id,
      store: store,
      previewProvider: provider
    )
    await gate.waitUntilFirstPreviewStarts()

    store.setSelectedDraftID(draftB.id)
    XCTAssertFalse(store.isPublishPreviewRefreshing)
    XCTAssertEqual(store.publishPackage, originalBPackage)
    XCTAssertEqual(store.localPublishPreview, originalBPreview)
    XCTAssertEqual(store.localPublishReadiness, originalBReadiness)
    XCTAssertEqual(store.remotePublishPreviewSnapshot, originalBRemote)
    XCTAssertEqual(store.remoteReviewDraft, originalBReviewDraft)

    await gate.releaseFirstPreview()
    await store.waitForPublishPreviewRefresh(for: draftA.id)

    XCTAssertEqual(store.cachedPublishPreview(for: draftA.id)?.context.draftID, draftA.id)
    XCTAssertEqual(store.selectedDraftID, draftB.id)
    XCTAssertEqual(store.publishPackage, originalBPackage)
    XCTAssertEqual(store.localPublishPreview, originalBPreview)
    XCTAssertEqual(store.localPublishReadiness, originalBReadiness)
    XCTAssertEqual(store.remotePublishPreviewSnapshot, originalBRemote)
    XCTAssertEqual(store.remoteReviewDraft, originalBReviewDraft)
  }

  func testBodyChangeDuringRefreshPreventsStalePreviewInstallation() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Body Stale",
      slug: "body-stale",
      draft: false,
      bodyMarkdown: "The preview must be discarded when the body changes mid-refresh."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let gate = AsyncPublishPreviewGate()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      await gate.suspendFirstPreview()
      return LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    }
    store.publishingStore.schedulePublishPreviewRefresh(
      for: draft.id,
      store: store,
      previewProvider: provider
    )
    await gate.waitUntilFirstPreviewStarts()

    var changedDraft = try XCTUnwrap(store.draft(for: draft.id))
    changedDraft.bodyMarkdown += "\n\nA newer paragraph invalidates the in-flight preview."
    store.updateDraft(changedDraft)
    await gate.releaseFirstPreview()
    await store.waitForPublishPreviewRefresh(for: draft.id)

    XCTAssertNil(store.cachedPublishPreview(for: draft.id))
  }

  func testCollisionInputChangeDuringRefreshPreventsStalePreviewInstallation() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let draftA = ArticleDraft(
      siteProfileID: profile.id,
      title: "Collision A",
      slug: "collision-a",
      draft: false,
      bodyMarkdown: "The preview must be discarded when another title changes collision inputs."
    )
    let draftB = ArticleDraft(
      siteProfileID: profile.id,
      title: "Collision B",
      slug: "collision-b",
      draft: false,
      bodyMarkdown: "A second article participates in the duplicate-title baseline."
    )
    store.setDrafts([draftA, draftB])
    store.setSelectedDraftID(draftA.id)

    let gate = AsyncPublishPreviewGate()
    let provider: PublishingStore.AsyncLocalPublishPreviewProvider = { package, _ in
      await gate.suspendFirstPreview()
      return LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    }
    store.publishingStore.schedulePublishPreviewRefresh(
      for: draftA.id,
      store: store,
      previewProvider: provider
    )
    await gate.waitUntilFirstPreviewStarts()

    var changedDraft = try XCTUnwrap(store.draft(for: draftB.id))
    changedDraft.title = "Collision B Updated"
    store.updateDraft(changedDraft)
    await gate.releaseFirstPreview()
    await store.waitForPublishPreviewRefresh(for: draftA.id)

    XCTAssertNil(store.cachedPublishPreview(for: draftA.id))
  }

  func testSelectedDraftCommandNeverUsesPreviousDraftPackage() throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.publishingStore.cancelPublishPreviewRefresh()
    let profile = store.activeProfile
    let previousDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Previous Article",
      slug: "previous-article",
      draft: false,
      bodyMarkdown: "This package must not be reused after selecting a different article."
    )
    let selectedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Selected Article",
      slug: "selected-article",
      draft: false,
      bodyMarkdown: "The command must regenerate the package for this selected article."
    )
    store.setDrafts([previousDraft, selectedDraft])
    store.setSelectedDraftID(previousDraft.id)
    store.refreshPublishPreview(for: previousDraft)
    XCTAssertEqual(store.publishPackage?.draftID, previousDraft.id)

    store.setSelectedDraftID(selectedDraft.id)
    _ = store.localCommitCommandForSelectedDraft()

    XCTAssertEqual(store.publishPackage?.draftID, selectedDraft.id)
    XCTAssertEqual(store.publishPackage?.title, selectedDraft.title)
  }

  private func assertEquivalent(_ actual: LocalPublishPreview, _ expected: LocalPublishPreview) {
    assertEquivalent(actual.package, expected.package)
    XCTAssertEqual(actual.fileDiffs, expected.fileDiffs)
    XCTAssertEqual(issueSignatures(actual.issues), issueSignatures(expected.issues))
  }

  private func assertEquivalent(
    _ actual: DraftPublishPreviewSnapshot,
    _ expected: DraftPublishPreviewSnapshot
  ) {
    XCTAssertEqual(actual.context, expected.context)
    assertEquivalent(actual.publishPackage, expected.publishPackage)
    assertEquivalent(actual.localPublishPreview, expected.localPublishPreview)
    assertEquivalent(actual.localPublishReadiness, expected.localPublishReadiness)
    assertEquivalent(actual.remotePublishPreview, expected.remotePublishPreview)
    XCTAssertEqual(actual.remoteReviewDraft, expected.remoteReviewDraft)
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

  func recordAndReturn(_ draftID: UUID) -> Int {
    recordedDraftIDs.append(draftID)
    return recordedDraftIDs.count
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
