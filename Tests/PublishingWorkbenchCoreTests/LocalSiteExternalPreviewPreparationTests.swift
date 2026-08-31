import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class LocalSiteExternalPreviewPreparationTests: XCTestCase {
  func testPreparationFlushesLatestEditorBodyBeforeReturningURLs() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "LocalSiteExternalPreviewPreparation"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let siteURL = rootURL.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: siteURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: siteURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("workbench.json")
      ),
      localSitePreviewService: LocalSitePreviewService(
        executableResolver: { _ in "/usr/bin/true" },
        portAllocator: LocalSitePreviewPortAllocator(
          isPortAvailable: { _ in true },
          dynamicPort: { nil }
        )
      )
    )
    store.updateActiveProfile { profile in
      profile.siteKind = .zola
      profile.localRepositoryRootPath = siteURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }

    var draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Browser Preview",
      slug: "browser-preview",
      bodyMarkdown: "old body"
    )
    draft.repositoryPath = "content/posts/browser-preview.md"
    store.setDrafts([draft])
    let stage = try XCTUnwrap(
      store.stageDraftBody(
        "latest editor body",
        for: draft.id,
        baseRevision: store.draftBodyEditorBuffer(for: draft.id).revision
      )
    )
    XCTAssertTrue(stage.wasAccepted)

    let preparation = try await store.prepareLocalSiteExternalPreview(for: draft.id)

    XCTAssertEqual(preparation.draftID, draft.id)
    XCTAssertEqual(preparation.profileID, store.activeProfileID)
    XCTAssertEqual(preparation.bodyRevision, stage.buffer.revision)
    XCTAssertEqual(preparation.siteURL.host, "127.0.0.1")
    XCTAssertEqual(preparation.articleURL.host, "127.0.0.1")
    let writtenBody = try String(
      contentsOf: siteURL.appendingPathComponent("content/posts/browser-preview.md"),
      encoding: .utf8
    )
    XCTAssertTrue(writtenBody.contains("latest editor body"))
    guard case .saved = store.siteDraftFileSaveStates[draft.id] else {
      return XCTFail("Preparation must await the target project write")
    }
  }

  func testPreparationRejectsDraftThatHasNotBeenAddedToProject() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ExternalPreviewUnboundDraft")
    var draft = ArticleDraft.empty(profile: store.activeProfile)
    draft.repositoryPath = nil
    store.setDrafts([draft])

    await assertPreparationError(.draftNotAddedToProject, store: store, draftID: draft.id)
  }

  func testPreparationRejectsGeneralDraft() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ExternalPreviewGeneralDraft")
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.setDrafts([draft])

    await assertPreparationError(.generalDraftRequiresProject, store: store, draftID: draft.id)
  }

  func testPreparationRejectsDraftOutsideActiveSite() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ExternalPreviewInactiveSite")
    var draft = ArticleDraft(siteProfileID: UUID(), title: "Other site", slug: "other-site")
    draft.repositoryPath = "content/posts/other-site.md"
    store.setDrafts([draft])

    await assertPreparationError(.inactiveSite, store: store, draftID: draft.id)
  }

  func testFinalValidationFailsClosedForStopGenerationManifestAndDiskChanges() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "LocalSiteExternalPreviewValidation"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let siteURL = rootURL.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: siteURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: siteURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let packageURL = siteURL.appendingPathComponent("package.json")
    try Data(#"{"scripts":{"dev":"astro dev"}}"#.utf8).write(to: packageURL)

    let processService = LocalSitePreviewProcessService(
      trustStore: LocalSitePreviewTrustStore(
        fileURL: rootURL.appendingPathComponent("preview-trust.json")
      )
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("workbench.json")
      ),
      localSitePreviewService: LocalSitePreviewService(
        executableResolver: { _ in "/bin/sleep" },
        portAllocator: LocalSitePreviewPortAllocator(
          isPortAvailable: { _ in true },
          dynamicPort: { nil }
        )
      ),
      localSitePreviewProcessService: processService
    )
    defer { store.stopLocalSitePreviewImmediately() }
    store.updateActiveProfile { profile in
      profile.siteKind = .astro
      profile.localRepositoryRootPath = siteURL.path
      profile.markdownPathPattern = "src/content/blog/{slug}.md"
    }

    var draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Validated Preview",
      slug: "validated-preview",
      bodyMarkdown: "validated body"
    )
    draft.repositoryPath = "src/content/blog/validated-preview.md"
    store.setDrafts([draft])
    let preparation = try await store.prepareLocalSiteExternalPreview(for: draft.id)
    let articleFileURL = siteURL.appendingPathComponent(
      "src/content/blog/validated-preview.md"
    )
    let expectedFileContents = try String(contentsOf: articleFileURL, encoding: .utf8)

    let plan = try makeControlledPreviewPlan(
      profileID: store.activeProfileID,
      rootPath: siteURL.path,
      siteKind: .astro,
      previewURL: preparation.siteURL
    )
    store.publishingStore.localSitePreviewPlan = plan
    try authorizeAndStart(plan: plan, store: store, processService: processService)
    var generation = store.localSitePreviewValidationGeneration
    let fingerprint = try XCTUnwrap(plan.executionIdentity?.fingerprint)

    var isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation
    )
    XCTAssertTrue(isCurrent)
    isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation &+ 1
    )
    XCTAssertFalse(isCurrent)

    try Data("externally replaced".utf8).write(to: articleFileURL)
    isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation
    )
    XCTAssertFalse(isCurrent)
    try Data(expectedFileContents.utf8).write(to: articleFileURL)
    isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation
    )
    XCTAssertTrue(isCurrent)

    store.stopLocalSitePreviewImmediately()
    isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation
    )
    XCTAssertFalse(isCurrent)

    try authorizeAndStart(plan: plan, store: store, processService: processService)
    generation = store.localSitePreviewValidationGeneration
    try Data(#"{"scripts":{"dev":"astro dev --changed"}}"#.utf8).write(to: packageURL)
    isCurrent = await store.isLocalSiteExternalPreviewCurrent(
      preparation,
      targetURL: preparation.articleURL,
      executionFingerprint: fingerprint,
      previewGeneration: generation
    )
    XCTAssertFalse(isCurrent)
  }

  private func assertPreparationError(
    _ expected: LocalSiteExternalPreviewPreparationError,
    store: WorkbenchStore,
    draftID: UUID
  ) async {
    do {
      _ = try await store.prepareLocalSiteExternalPreview(for: draftID)
      XCTFail("Expected preparation to fail")
    } catch let error as LocalSiteExternalPreviewPreparationError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeControlledPreviewPlan(
    profileID: UUID,
    rootPath: String,
    siteKind: SiteKind,
    previewURL: URL
  ) throws -> LocalSitePreviewPlan {
    let arguments = ["30"]
    let executablePath = "/bin/sleep"
    let command = "sleep 30"
    let identity = try LocalSitePreviewExecutionFingerprint.makeIdentity(
      profileID: profileID,
      rootPath: rootPath,
      siteKind: siteKind,
      executablePath: executablePath,
      arguments: arguments,
      command: command
    )
    return LocalSitePreviewPlan(
      siteKind: siteKind,
      rootPath: identity.canonicalRootPath,
      executablePath: executablePath,
      arguments: arguments,
      command: command,
      previewURL: previewURL,
      notes: [],
      executionIdentity: identity
    )
  }

  private func authorizeAndStart(
    plan: LocalSitePreviewPlan,
    store: WorkbenchStore,
    processService: LocalSitePreviewProcessService
  ) throws {
    if let request = try processService.authorizationRequest(for: plan) {
      try processService.authorize(plan: plan, matching: request)
    }
    store.publishingStore.localSitePreviewPlan = plan
    guard case .started = store.publishingStore.startLocalSitePreview() else {
      return XCTFail("Expected controlled preview process to start")
    }
    XCTAssertTrue(store.localSitePreviewRuntimeStatus.isRunning)
  }
}
