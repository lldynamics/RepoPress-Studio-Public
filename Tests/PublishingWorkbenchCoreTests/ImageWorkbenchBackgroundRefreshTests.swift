import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ImageWorkbenchBackgroundRefreshTests: XCTestCase {
  func testAsyncReportAndSiteSummaryMatchSynchronousResults() async throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Async image report",
      slug: "async-image-report",
      bodyMarkdown: "No image attachments"
    )
    let service = SiteImageWorkbenchService()

    let synchronousReport = service.report(draft: draft, profile: profile)
    let asynchronousReport = try await service.reportAsync(draft: draft, profile: profile)
    XCTAssertEqual(asynchronousReport.draftID, synchronousReport.draftID)
    XCTAssertEqual(asynchronousReport.items, synchronousReport.items)
    XCTAssertEqual(asynchronousReport.coverStatus, synchronousReport.coverStatus)
    XCTAssertEqual(
      asynchronousReport.issues.map(semanticIssueIdentity),
      synchronousReport.issues.map(semanticIssueIdentity)
    )

    let synchronousSummary = service.siteSummary(drafts: [draft], profile: profile)
    let asynchronousSummary = try await service.siteSummaryAsync(drafts: [draft], profile: profile)
    XCTAssertEqual(asynchronousSummary, synchronousSummary)
  }

  @MainActor
  func testOlderBackgroundReportCannotOverwriteChangedDraftResult() async throws {
    let tracker = AsyncReportInvocationTracker()
    let baseService = SiteImageWorkbenchService()
    let service = SiteImageWorkbenchService(
      asyncReportOperation: { draft, profile in
        await tracker.recordStart(title: draft.title)
        if draft.title == "Original" || draft.title == "Profile Baseline" {
          try await Task.sleep(for: .milliseconds(200))
        } else {
          try await Task.sleep(for: .milliseconds(10))
        }
        var report = baseService.report(draft: draft, profile: profile)
        report.issues = [
          ImageWorkbenchIssue(
            severity: .warning,
            title: draft.title,
            message: "Result for \(draft.title)"
          )
        ]
        return report
      }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      imageWorkbenchService: service
    )
    let draftID = try XCTUnwrap(store.drafts.first?.id)
    store.selectDraft(draftID)

    var original = try XCTUnwrap(store.selectedDraft)
    original.title = "Original"
    store.updateDraft(original)
    original = try XCTUnwrap(store.selectedDraft)

    let olderRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: original, force: true)
    }
    await tracker.waitUntilStarted(title: "Original")

    var changed = try XCTUnwrap(store.selectedDraft)
    changed.title = "Changed"
    store.updateDraft(changed)
    changed = try XCTUnwrap(store.selectedDraft)

    let currentRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: changed, force: true)
    }
    await currentRefresh.value
    await olderRefresh.value

    let cached = try XCTUnwrap(store.cachedImageWorkbenchReport(for: changed))
    XCTAssertEqual(cached.issues.first?.title, "Changed")
    // Title-only edits do not change the semantic inputs of a per-draft image
    // report, so the current report remains reusable for that value as well.
    XCTAssertNotNil(store.cachedImageWorkbenchReport(for: original))
    XCTAssertFalse(store.isImageWorkbenchReportLoading(for: changed))

    var profileBaselineDraft = changed
    profileBaselineDraft.title = "Profile Baseline"
    store.updateDraft(profileBaselineDraft)
    profileBaselineDraft = try XCTUnwrap(store.selectedDraft)
    let profileRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: profileBaselineDraft, force: true)
    }
    await tracker.waitUntilStarted(title: "Profile Baseline")

    var changedProfile = store.activeProfile
    changedProfile.includeCoverInFrontMatter.toggle()
    store.updateActiveProfile(changedProfile)
    await profileRefresh.value

    XCTAssertNil(store.cachedImageWorkbenchReport(for: profileBaselineDraft))
    XCTAssertFalse(store.isImageWorkbenchReportLoading(for: profileBaselineDraft))
  }

  @MainActor
  func testScheduledCacheRefreshKeepsRootStoreAliveUntilAsyncChildrenFinish() async throws {
    let gate = ImageRefreshLifetimeGate(expectedStarts: 2)
    let baseService = SiteImageWorkbenchService()
    let service = SiteImageWorkbenchService(
      asyncReportOperation: { draft, profile in
        await gate.suspendUntilReleased()
        return baseService.report(draft: draft, profile: profile)
      },
      asyncSiteSummaryOperation: { drafts, profile in
        await gate.suspendUntilReleased()
        return baseService.siteSummary(drafts: drafts, profile: profile)
      }
    )

    var store: WorkbenchStore? = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      imageWorkbenchService: service
    )
    weak let weakStore = store
    let draft = try XCTUnwrap(store?.selectedDraft)

    store?.scheduleImageWorkbenchCachesRefresh(for: draft, force: true)
    await gate.waitUntilAllStarted()
    store = nil

    XCTAssertNotNil(
      weakStore,
      "The in-flight image refresh must retain its root owner across suspension."
    )

    await gate.releaseAll()
    for _ in 0 ..< 100 where weakStore != nil {
      await Task.yield()
    }
    XCTAssertNil(weakStore)
  }

  func testImageInputSignaturesIgnoreOrdinaryProseAndTrackImageChanges() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "hero.jpg",
      relativePublishPath: "/images/hero.jpg",
      repositoryPath: "static/images/hero.jpg",
      altText: "Hero",
      caption: "Caption",
      byteSize: 128,
      sourceFilePath: "/tmp/hero.jpg"
    )
    let original = ArticleDraft(
      siteProfileID: profile.id,
      title: "Image signature",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "Intro\n\n![Hero](/images/hero.jpg)\n",
      attachments: [attachment]
    )

    var proseEdit = original
    proseEdit.bodyMarkdown += "\nAn ordinary paragraph with no image."
    XCTAssertEqual(
      ImageWorkbenchReportInputSignature(draft: original, profile: profile),
      ImageWorkbenchReportInputSignature(draft: proseEdit, profile: profile)
    )
    XCTAssertEqual(
      ImageWorkbenchSiteSummaryInputSignature(drafts: [original], profile: profile),
      ImageWorkbenchSiteSummaryInputSignature(drafts: [proseEdit], profile: profile)
    )

    var imageReferenceEdit = proseEdit
    imageReferenceEdit.bodyMarkdown += "\n![Detail](/images/detail.png)"
    XCTAssertNotEqual(
      ImageWorkbenchReportInputSignature(draft: original, profile: profile),
      ImageWorkbenchReportInputSignature(draft: imageReferenceEdit, profile: profile)
    )

    var attachmentEdit = proseEdit
    attachmentEdit.attachments[0].caption = "Updated caption"
    XCTAssertNotEqual(
      ImageWorkbenchReportInputSignature(draft: original, profile: profile),
      ImageWorkbenchReportInputSignature(draft: attachmentEdit, profile: profile)
    )
  }

  @MainActor
  func testOrdinaryProseKeepsCachedReportWhileImageInputsInvalidateIt() async throws {
    let tracker = AsyncReportInvocationTracker()
    let baseService = SiteImageWorkbenchService()
    let service = SiteImageWorkbenchService(
      asyncReportOperation: { draft, profile in
        await tracker.recordStart(title: draft.title)
        return baseService.report(draft: draft, profile: profile)
      }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      imageWorkbenchService: service
    )
    let draftID = try XCTUnwrap(store.drafts.first?.id)
    store.setSelectedDraftID(draftID)
    var draft = try XCTUnwrap(store.selectedDraft)

    await store.refreshImageWorkbenchReportInBackground(for: draft, force: true)
    var startCount = await tracker.startCount
    XCTAssertEqual(startCount, 1)

    draft.bodyMarkdown += "\nThis is ordinary prose."
    store.updateDraft(draft)
    draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertNotNil(store.cachedImageWorkbenchReport(for: draft))
    await store.refreshImageWorkbenchReportInBackground(for: draft)
    startCount = await tracker.startCount
    XCTAssertEqual(startCount, 1)

    draft.bodyMarkdown += "\n![New image](/images/new.png)"
    store.updateDraft(draft)
    draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertNil(store.cachedImageWorkbenchReport(for: draft))
    await store.refreshImageWorkbenchReportInBackground(for: draft)
    startCount = await tracker.startCount
    XCTAssertEqual(startCount, 2)

    draft.attachments.append(
      DraftAttachment(
        originalFilename: "new.png",
        relativePublishPath: "/images/new.png",
        repositoryPath: "static/images/new.png"
      )
    )
    store.updateDraft(draft)
    draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertNil(store.cachedImageWorkbenchReport(for: draft))
    await store.refreshImageWorkbenchReportInBackground(for: draft)
    startCount = await tracker.startCount
    XCTAssertEqual(startCount, 3)
  }

  @MainActor
  func testSupersededScansAreCancelledWithoutAccumulating() async throws {
    let tracker = CancellableReportInvocationTracker()
    let baseService = SiteImageWorkbenchService()
    let service = SiteImageWorkbenchService(
      asyncReportOperation: { draft, profile in
        try await tracker.perform(title: draft.title)
        return baseService.report(draft: draft, profile: profile)
      }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()),
      imageWorkbenchService: service
    )
    let draftID = try XCTUnwrap(store.drafts.first?.id)
    store.setSelectedDraftID(draftID)

    var first = try XCTUnwrap(store.selectedDraft)
    first.title = "First"
    store.updateDraft(first)
    first = try XCTUnwrap(store.selectedDraft)
    let firstRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: first, force: true)
    }
    await tracker.waitUntilStarted(title: "First")

    var second = first
    second.title = "Second"
    store.updateDraft(second)
    second = try XCTUnwrap(store.selectedDraft)
    let secondRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: second, force: true)
    }
    await tracker.waitUntilStarted(title: "Second")
    await tracker.waitForCancellationCount(1)

    var final = second
    final.title = "Final"
    store.updateDraft(final)
    final = try XCTUnwrap(store.selectedDraft)
    let finalRefresh = Task { @MainActor in
      await store.refreshImageWorkbenchReportInBackground(for: final, force: true)
    }
    await tracker.waitUntilStarted(title: "Final")
    await tracker.waitForCancellationCount(2)

    await finalRefresh.value
    await secondRefresh.value
    await firstRefresh.value

    let snapshot = await tracker.snapshot
    XCTAssertEqual(snapshot.started, 3)
    XCTAssertEqual(snapshot.cancelled, 2)
    XCTAssertEqual(snapshot.completed, 1)
    XCTAssertEqual(snapshot.active, 0)
    XCTAssertLessThanOrEqual(snapshot.maximumActive, 2)
    XCTAssertNotNil(store.cachedImageWorkbenchReport(for: final))
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("image-workbench-background-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("workbench.json")
  }

  private func semanticIssueIdentity(_ issue: ImageWorkbenchIssue) -> String {
    [
      issue.severity.rawValue,
      issue.title,
      issue.message,
      issue.attachmentID?.uuidString ?? "",
    ].joined(separator: "|")
  }
}

private actor AsyncReportInvocationTracker {
  private var startedTitles = Set<String>()
  private var totalStartCount = 0

  var startCount: Int { totalStartCount }

  func recordStart(title: String) {
    startedTitles.insert(title)
    totalStartCount += 1
  }

  func waitUntilStarted(title: String) async {
    while !startedTitles.contains(title) {
      await Task.yield()
    }
  }
}

private actor CancellableReportInvocationTracker {
  struct Snapshot: Sendable {
    let started: Int
    let cancelled: Int
    let completed: Int
    let active: Int
    let maximumActive: Int
  }

  private var startedTitles = Set<String>()
  private var cancellationCount = 0
  private var completedCount = 0
  private var activeCount = 0
  private var maximumActiveCount = 0

  var snapshot: Snapshot {
    Snapshot(
      started: startedTitles.count,
      cancelled: cancellationCount,
      completed: completedCount,
      active: activeCount,
      maximumActive: maximumActiveCount
    )
  }

  func perform(title: String) async throws {
    startedTitles.insert(title)
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    do {
      if title == "Final" {
        try await Task.sleep(for: .milliseconds(10))
      } else {
        try await Task.sleep(for: .seconds(10))
      }
      activeCount -= 1
      completedCount += 1
    } catch {
      activeCount -= 1
      if error is CancellationError {
        cancellationCount += 1
      }
      throw error
    }
  }

  func waitUntilStarted(title: String) async {
    while !startedTitles.contains(title) {
      await Task.yield()
    }
  }

  func waitForCancellationCount(_ expectedCount: Int) async {
    while cancellationCount < expectedCount {
      await Task.yield()
    }
  }
}

private actor ImageRefreshLifetimeGate {
  private let expectedStarts: Int
  private var startCount = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(expectedStarts: Int) {
    self.expectedStarts = expectedStarts
  }

  func suspendUntilReleased() async {
    startCount += 1
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitUntilAllStarted() async {
    while startCount < expectedStarts {
      await Task.yield()
    }
  }

  func releaseAll() {
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}
