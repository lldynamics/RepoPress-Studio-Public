import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingConflictResolutionTests:
  WorkbenchStoreRemotePublishingTestCase
{
  func testIncompleteTwoFilePlanPerformsNoRemoteRequestOrDraftMutation() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "IncompleteConflictPlan"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )
    let profile = store.activeProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "First local body"
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: "Second local body"
    )
    store.setDrafts([first, second])
    let originalDrafts = store.drafts
    let session = conflictSession(profile: profile, draftIDs: [first.id, second.id])
    store.publishingStore.remoteRepositoryConflictSession = session

    let outcome = await store.resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          .init(repositoryPath: session.conflicts[0].repositoryPath, choice: .keepLocal)
        ]
      )
    )

    guard case .failed = outcome else {
      return XCTFail("An incomplete transaction must remain recoverable in the resolver")
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(store.drafts, originalDrafts)
    XCTAssertEqual(store.remoteRepositoryConflictSession, session)
  }

  func testLegacySinglePathEntryCannotPublishMultiFileConflict() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "LegacySingleConflictEntry"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )
    let profile = store.activeProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "First local body"
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: "Second local body"
    )
    store.setDrafts([first, second])
    let session = conflictSession(profile: profile, draftIDs: [first.id, second.id])
    store.publishingStore.remoteRepositoryConflictSession = session

    let outcome = await store.resolveRemoteRepositoryConflict(
      repositoryPath: session.conflicts[0].repositoryPath,
      choice: .keepLocal
    )

    guard case .failed = outcome else {
      return XCTFail("The compatibility entry must reject a multi-file session")
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(store.remoteRepositoryConflictSession, session)
  }

  func testInvalidSecondMergeLeavesWholeTransactionUntouched() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "InvalidConflictMerge"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )
    let profile = store.activeProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "first",
      bodyMarkdown: "First local body"
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "second",
      bodyMarkdown: "Second local body"
    )
    store.setDrafts([first, second])
    let originalDrafts = store.drafts
    let session = conflictSession(profile: profile, draftIDs: [first.id, second.id])
    store.publishingStore.remoteRepositoryConflictSession = session

    let outcome = await store.resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          .init(repositoryPath: session.conflicts[0].repositoryPath, choice: .keepLocal),
          .init(
            repositoryPath: session.conflicts[1].repositoryPath,
            choice: .merge,
            mergedDocument: "<<<<<<< local\nbody\n=======\nremote\n>>>>>>> remote"
          ),
        ]
      )
    )

    guard case .failed = outcome else {
      return XCTFail("An invalid merge must reject the whole transaction")
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(store.drafts, originalDrafts)
    XCTAssertEqual(store.remoteRepositoryConflictSession, session)
  }

  func testAllUseRemoteAppliesBothDraftsAfterFullReadOnlyRevalidation() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "AllUseRemoteConflictResolution")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let tokenStore = repositoryTokenStoreForTest()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "AllUseRemoteConflictResolution"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let firstPath = "content/posts/first.md"
    let secondPath = "content/posts/second.md"
    var first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First Local",
      slug: "first",
      draft: false,
      bodyMarkdown:
        "This first local article body is intentionally long enough to remain publishable during conflict resolution.",
      status: .ready,
      repositoryPath: firstPath,
      repositorySHA: "old-first"
    )
    var second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second Local",
      slug: "second",
      draft: false,
      bodyMarkdown:
        "This second local article body is intentionally long enough to remain publishable during conflict resolution.",
      status: .ready,
      repositoryPath: secondPath,
      repositorySHA: "old-second"
    )
    first.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: firstPath,
      remoteRevision: "old-first",
      renderedContentDigest: first.renderedRepositoryContentDigest(profile: profile)
    )
    second.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: secondPath,
      remoteRevision: "old-second",
      renderedContentDigest: second.renderedRepositoryContentDigest(profile: profile)
    )
    store.setDrafts([first, second])
    store.setSelectedDraftID(first.id)
    store.refreshBatchPublishPlan()
    let batchPlan = try XCTUnwrap(store.batchPublishPlan)
    let package = try XCTUnwrap(store.remotePublishPackage(for: batchPlan))

    var remoteFirst = first
    remoteFirst.title = "First Remote"
    remoteFirst.bodyMarkdown =
      "This first remote article body replaces the local version only after the whole transaction is validated."
    var remoteSecond = second
    remoteSecond.title = "Second Remote"
    remoteSecond.bodyMarkdown =
      "This second remote article body replaces the local version in the same atomic draft update."
    let packageBuilder = PublishPackageBuilder()
    let remoteDocuments = [
      firstPath: try XCTUnwrap(
        packageBuilder.build(draft: remoteFirst, profile: profile).markdownFile?.content
      ),
      secondPath: try XCTUnwrap(
        packageBuilder.build(draft: remoteSecond, profile: profile).markdownFile?.content
      ),
    ]
    let actualSHAs = [firstPath: "new-first", secondPath: "new-second"]
    let files = package.files.filter { $0.kind == .markdown }
    XCTAssertEqual(files.map(\.repositoryPath), [firstPath, secondPath])

    var responses: [WorkbenchRemoteRepositoryTransportResponse] = files.map { file in
      let remote = remoteDocuments[file.repositoryPath] ?? ""
      let encoded = Data(remote.utf8).base64EncodedString()
      return workbenchRemoteResponse(
        json:
          #"{"sha":"\#(actualSHAs[file.repositoryPath] ?? "")","content":"\#(encoded)","encoding":"base64"}"#
      )
    }
    responses.append(
      contentsOf: files.map { file in
        let base = file.content ?? ""
        let encoded = Data(base.utf8).base64EncodedString()
        return workbenchRemoteResponse(
          json:
            #"{"sha":"\#(file.expectedRemoteSHA ?? "")","content":"\#(encoded)","encoding":"base64"}"#
        )
      }
    )
    await transport.replaceResponses(responses)

    let session = RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: RemoteRepositoryPublishService()
        .conflictPackageFingerprint(package: package, profile: profile),
      publishScope: .batch(batchPlan.remotePublishableItems.map(\.draftID)),
      conflicts: files.map { file in
        let path = file.repositoryPath
        return RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: file.kind,
          operation: file.operation,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: actualSHAs[path],
          base: .text(file.content ?? ""),
          local: .text(file.content ?? ""),
          remote: .text(remoteDocuments[path] ?? "")
        )
      }
    )
    store.publishingStore.remoteRepositoryConflictSession = session

    let outcome = await store.resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: session.conflicts.map {
          .init(repositoryPath: $0.repositoryPath, choice: .useRemote)
        }
      )
    )

    guard case .completed = outcome else {
      return XCTFail(
        "A fully revalidated use-remote transaction should complete: \(outcome.message)\n"
          + "reviewed=\(session.conflicts)\n"
          + "current=\(String(describing: store.remoteRepositoryConflictSession?.conflicts))"
      )
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertFalse(
      requests.contains { ["POST", "PUT", "PATCH", "DELETE"].contains($0.httpMethod ?? "") }
    )
    XCTAssertEqual(store.drafts.first(where: { $0.id == first.id })?.title, "First Remote")
    XCTAssertEqual(store.drafts.first(where: { $0.id == second.id })?.title, "Second Remote")
    XCTAssertEqual(store.drafts.first(where: { $0.id == first.id })?.repositorySHA, "new-first")
    XCTAssertEqual(store.drafts.first(where: { $0.id == second.id })?.repositorySHA, "new-second")
    XCTAssertNil(store.remoteRepositoryConflictSession)
  }

  func testMixedMergeAndKeepLocalCreateOneAtomicCommitAndOnePullRequest() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "KeepLocalConflictResolution")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let tokenStore = repositoryTokenStoreForTest()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "KeepLocalConflictResolution"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: RepositoryProvider.github.defaultBaseURL,
        defaultBranch: "main",
        canRead: true,
        canWrite: true,
        message: "Writable"
      )
    )

    let firstPath = "content/posts/first.md"
    let secondPath = "content/posts/second.md"
    var first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First Local",
      slug: "first",
      draft: false,
      bodyMarkdown:
        "This first local article body is intentionally long enough for one atomic review request.",
      status: .ready,
      repositoryPath: firstPath
    )
    var second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second Local",
      slug: "second",
      draft: false,
      bodyMarkdown:
        "This second local article body is intentionally long enough for the same atomic review request.",
      status: .ready,
      repositoryPath: secondPath
    )
    first.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: firstPath,
      remoteRevision: "old-first",
      renderedContentDigest: first.renderedRepositoryContentDigest(profile: profile)
    )
    second.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: secondPath,
      remoteRevision: "old-second",
      renderedContentDigest: second.renderedRepositoryContentDigest(profile: profile)
    )
    store.setDrafts([first, second])
    store.setSelectedDraftID(first.id)
    store.refreshBatchPublishPlan()
    let batchPlan = try XCTUnwrap(store.batchPublishPlan)
    let package = try XCTUnwrap(store.remotePublishPackage(for: batchPlan))
    let files = package.files.filter { $0.kind == .markdown }
    XCTAssertEqual(files.map(\.repositoryPath), [firstPath, secondPath])
    let mergedFirstDocument = try XCTUnwrap(
      files.first(where: { $0.repositoryPath == firstPath })?.content
    ).replacingOccurrences(of: "First Local", with: "First Resolved")

    let remoteDocuments = [
      firstPath: (files.first { $0.repositoryPath == firstPath }?.content ?? "")
        .replacingOccurrences(of: "First Local", with: "First Remote"),
      secondPath: (files.first { $0.repositoryPath == secondPath }?.content ?? "")
        .replacingOccurrences(of: "Second Local", with: "Second Remote"),
    ]
    let actualSHAs = [firstPath: "new-first", secondPath: "new-second"]
    var responses: [WorkbenchRemoteRepositoryTransportResponse] = files.map { file in
      let encoded = Data((remoteDocuments[file.repositoryPath] ?? "").utf8).base64EncodedString()
      return workbenchRemoteResponse(
        json:
          #"{"sha":"\#(actualSHAs[file.repositoryPath] ?? "")","content":"\#(encoded)","encoding":"base64"}"#
      )
    }
    responses.append(
      contentsOf: files.map { file in
        let encoded = Data((file.content ?? "").utf8).base64EncodedString()
        return workbenchRemoteResponse(
          json:
            #"{"sha":"\#(file.expectedRemoteSHA ?? "")","content":"\#(encoded)","encoding":"base64"}"#
        )
      }
    )
    responses.append(contentsOf: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit"}}"#),
      workbenchRemoteResponse(
        json: #"{"ref":"refs/heads/publish/conflicts","object":{"sha":"base-commit"}}"#
      ),
      workbenchRemoteResponse(
        json:
          #"{"sha":"base-commit","tree":{"sha":"base-tree"},"parents":[{"sha":"parent"}]}"#
      ),
      workbenchRemoteResponse(json: #"{"sha":"new-first"}"#),
      workbenchRemoteResponse(json: #"{"sha":"local-first-blob"}"#),
      workbenchRemoteResponse(json: #"{"sha":"new-second"}"#),
      workbenchRemoteResponse(json: #"{"sha":"local-second-blob"}"#),
      workbenchRemoteResponse(json: #"{"sha":"resolved-tree"}"#),
      workbenchRemoteResponse(
        json:
          #"{"sha":"resolved-commit","tree":{"sha":"resolved-tree"},"parents":[{"sha":"base-commit"}]}"#
      ),
      workbenchRemoteResponse(json: #"{"object":{"sha":"resolved-commit"}}"#),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/42"}"#),
    ])
    await transport.replaceResponses(responses)

    let session = RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: RemoteRepositoryPublishService()
        .conflictPackageFingerprint(package: package, profile: profile),
      publishScope: .batch(batchPlan.remotePublishableItems.map(\.draftID)),
      conflicts: files.map { file in
        let path = file.repositoryPath
        return RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: file.kind,
          operation: file.operation,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: actualSHAs[path],
          base: .text(file.content ?? ""),
          local: .text(file.content ?? ""),
          remote: .text(remoteDocuments[path] ?? "")
        )
      }
    )
    store.publishingStore.remoteRepositoryConflictSession = session

    let outcome = await store.resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: session.conflicts.map { item in
          item.repositoryPath == firstPath
            ? .init(
              repositoryPath: item.repositoryPath,
              choice: .merge,
              mergedDocument: mergedFirstDocument
            )
            : .init(repositoryPath: item.repositoryPath, choice: .keepLocal)
        }
      )
    )

    guard case .completed = outcome else {
      return XCTFail("Mixed conflict transaction failed: \(outcome.message)")
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(
      requests.filter { $0.url?.path.hasSuffix("/git/trees") == true }.count,
      1
    )
    XCTAssertEqual(
      requests.filter { $0.url?.path.hasSuffix("/git/commits") == true }.count,
      1
    )
    XCTAssertEqual(
      requests.filter { $0.httpMethod == "PATCH" && $0.url?.path.contains("/git/refs/") == true }
        .count,
      1
    )
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/pulls") == true }.count, 1)
    XCTAssertEqual(store.remoteRepositoryPublishResult?.mode, .reviewRequest)
    XCTAssertEqual(store.remoteRepositoryPublishResult?.reviewURL, "https://github.com/owner/site/pull/42")
    XCTAssertEqual(store.drafts.first(where: { $0.id == first.id })?.title, "First Resolved")
    XCTAssertNil(store.remoteRepositoryConflictSession)
  }

  func testResolvedPackageKeepsFrozenFileSetAndProjectsOnlyReviewedPaths() throws {
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "FrozenConflictPackage")
    )
    let markdownPath = "content/posts/article.md"
    let imagePath = "static/images/cover.png"
    let untouchedPath = "static/images/untouched.png"
    let originalImage = PublishPackageFile(
      kind: .image,
      repositoryPath: imagePath,
      sourceFilePath: "/tmp/original-cover.png",
      byteSize: 7,
      expectedRemoteSHA: "old-image"
    )
    let untouchedImage = PublishPackageFile(
      kind: .image,
      repositoryPath: untouchedPath,
      sourceFilePath: "/tmp/untouched.png",
      byteSize: 9,
      expectedRemoteSHA: "same-image"
    )
    let frozen = PublishPackage(
      draftID: UUID(),
      title: "Frozen",
      markdownPath: markdownPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: markdownPath,
          content: "local",
          byteSize: 5,
          expectedRemoteSHA: "old-markdown"
        ),
        originalImage,
        untouchedImage,
      ],
      commitMessage: "Resolve",
      reviewBranchName: "publish/resolve",
      reviewTitle: "Resolve",
      reviewChecklist: []
    )
    let remoteDocument = "remote\n\n![new](../../static/images/new.png)"
    let session = RemoteRepositoryConflictSession(
      profileID: store.activeProfileID,
      repositoryIdentity: DraftRepositoryIdentity(profile: store.activeProfile),
      packageFingerprint: "fingerprint",
      conflicts: [
        RemoteRepositoryConflictItem(
          repositoryPath: markdownPath,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old-markdown",
          actualSHA: "new-markdown",
          base: .text("base"),
          local: .text("local"),
          remote: .text(remoteDocument)
        ),
        RemoteRepositoryConflictItem(
          repositoryPath: imagePath,
          fileKind: .image,
          operation: .upsert,
          expectedSHA: "old-image",
          actualSHA: "new-image",
          base: .diagnostic(.binary, byteCount: 7, message: "binary"),
          local: .diagnostic(.binary, byteCount: 7, message: "binary"),
          remote: .diagnostic(.binary, byteCount: 7, message: "binary")
        ),
      ]
    )
    let decisions = [
      markdownPath: RemoteRepositoryConflictResolutionDecision(
        repositoryPath: markdownPath,
        choice: .useRemote
      ),
      imagePath: RemoteRepositoryConflictResolutionDecision(
        repositoryPath: imagePath,
        choice: .keepLocal
      ),
    ]

    let resolved = try XCTUnwrap(
      store.publishingStore.resolvedRemoteConflictPublishPackage(
        frozenPackage: frozen,
        session: session,
        decisionsByPath: decisions
      )
    )

    XCTAssertEqual(resolved.files.map(\.repositoryPath), frozen.files.map(\.repositoryPath))
    XCTAssertEqual(resolved.files.first(where: { $0.repositoryPath == markdownPath })?.content, remoteDocument)
    XCTAssertEqual(resolved.files.first(where: { $0.repositoryPath == imagePath }), originalImage)
    XCTAssertEqual(resolved.files.first(where: { $0.repositoryPath == untouchedPath }), untouchedImage)
    XCTAssertFalse(resolved.files.contains { $0.repositoryPath.contains("new.png") })
  }

  func testConflictResolutionLockRejectsLocalRepositoryMutation() throws {
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "ConflictResolutionLock")
    )
    store.publishingStore.remoteConflictResolutionOperationID = UUID()

    XCTAssertTrue(store.isRemoteConflictResolutionRunning)
    XCTAssertNil(
      store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile)
    )
  }

  func testConflictResolutionLockBlocksBranchCreationAndSwitch() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ConflictResolutionBranchLock")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "ConflictResolutionBranchLock")
    )
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    let originalBranch = try git(["branch", "--show-current"], rootURL: rootURL)
    store.publishingStore.remoteConflictResolutionOperationID = UUID()

    await store.createAndSwitchActiveProfileRepositoryBranch(name: "blocked-conflict-branch")

    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: rootURL), originalBranch)
    XCTAssertFalse(
      try git(["branch", "--list", "blocked-conflict-branch"], rootURL: rootURL)
        .contains("blocked-conflict-branch")
    )
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
  }

  #if DEBUG
    func testConflictResolutionCancelsAndAwaitsAlreadyRunningAutoSyncBeforeRevalidation()
      async throws
    {
      let rootURL = try preparedGitRepositoryRoot(prefix: "ConflictResolutionAutoSyncRace")
      defer { try? FileManager.default.removeItem(at: rootURL) }
      let tokenStore = repositoryTokenStoreForTest()
      let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
      let store = WorkbenchStore(
        persistence: try TestWorkbenchFactory.persistence(prefix: "ConflictResolutionAutoSyncRace"),
        remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
        repositoryTokenStore: tokenStore
      )
      var profile = store.activeProfile
      profile.repositoryProvider = .github
      profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
      profile.repoOwner = "owner"
      profile.repoName = "site"
      profile.branch = "main"
      profile.repositoryPublishStrategy = .direct
      profile.markdownPathPattern = "content/posts/{slug}.md"
      profile.rememberLocalRepositoryRoot(rootURL)
      store.updateActiveProfile(profile)
      defer { try? tokenStore.deleteToken(for: profile) }
      try tokenStore.saveRepositoryToken("github-token", for: profile)
      store.refreshRepositoryTokenAvailability()

      let path = "content/posts/auto-sync-race.md"
      var draft = ArticleDraft(
        siteProfileID: profile.id,
        title: "Local Auto Sync Race",
        slug: "auto-sync-race",
        draft: false,
        bodyMarkdown:
          "This reviewed local body must not race an already running automatic repository import.",
        status: .ready,
        repositoryPath: path
      )
      draft.confirmRepositoryBinding(
        profile: profile,
        repositoryPath: path,
        remoteRevision: "old-sha",
        renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
      )
      store.setDrafts([draft])
      store.setSelectedDraftID(draft.id)
      store.refreshBatchPublishPlan()
      let batchPlan = try XCTUnwrap(store.batchPublishPlan)
      let package = try XCTUnwrap(store.remotePublishPackage(for: batchPlan))
      let localDocument = try XCTUnwrap(package.markdownFile?.content)
      var remoteDraft = draft
      remoteDraft.title = "Remote Auto Sync Race"
      remoteDraft.bodyMarkdown =
        "This remote body is adopted only after the running auto-sync has been cancelled and awaited."
      let remoteDocument = try XCTUnwrap(
        PublishPackageBuilder().build(draft: remoteDraft, profile: profile).markdownFile?.content
      )
      let remoteResponse = workbenchRemoteResponse(
        json:
          #"{"sha":"new-sha","content":"\#(Data(remoteDocument.utf8).base64EncodedString())","encoding":"base64"}"#
      )
      let baseResponse = workbenchRemoteResponse(
        json:
          #"{"sha":"old-sha","content":"\#(Data(localDocument.utf8).base64EncodedString())","encoding":"base64"}"#
      )
      await transport.replaceResponses([remoteResponse, baseResponse])

      let session = RemoteRepositoryConflictSession(
        profileID: profile.id,
        repositoryIdentity: DraftRepositoryIdentity(profile: profile),
        packageFingerprint: RemoteRepositoryPublishService()
          .conflictPackageFingerprint(package: package, profile: profile),
        publishScope: .batch(batchPlan.remotePublishableItems.map(\.draftID)),
        conflicts: [
          RemoteRepositoryConflictItem(
            repositoryPath: path,
            fileKind: .markdown,
            operation: .upsert,
            expectedSHA: "old-sha",
            actualSHA: "new-sha",
            base: .text(localDocument),
            local: .text(localDocument),
            remote: .text(remoteDocument)
          )
        ]
      )
      store.publishingStore.remoteRepositoryConflictSession = session

      store.updateRepositoryAutoSyncSettings(
        RepositoryAutoSyncSettings(
          isEnabled: true,
          intervalMinutes: 5,
          fetchBeforeScan: false,
          autoImportRemoteArticles: true
        )
      )
      let gate = RemoteImportTestGate()
      store.repositoryStore.repositoryAutoSyncBeforeImportTestHook = {
        await gate.waitUntilEntered()
      }
      let autoSyncTask = Task { @MainActor in
        await store.runRepositoryAutoSync(now: Date(timeIntervalSince1970: 1_900_001_000))
      }
      for _ in 0..<100 where !(await gate.hasEntered()) {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let autoSyncReachedImportBoundary = await gate.hasEntered()
      XCTAssertTrue(autoSyncReachedImportBoundary)

      let resolutionTask = Task { @MainActor in
        await store.resolveRemoteRepositoryConflicts(
          plan: RemoteRepositoryConflictResolutionPlan(
            sessionID: session.id,
            decisions: [.init(repositoryPath: path, choice: .useRemote)]
          )
        )
      }
      for _ in 0..<100 where !store.isRemoteConflictResolutionRunning {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(store.isRemoteConflictResolutionRunning)
      let requestsBeforeAutoSyncRelease = await transport.capturedRequests()
      XCTAssertEqual(requestsBeforeAutoSyncRelease.count, 0)

      await gate.release()
      let autoSyncCompleted = await autoSyncTask.value
      XCTAssertFalse(autoSyncCompleted)
      let outcome = await resolutionTask.value

      guard case .completed = outcome else {
        return XCTFail("The transaction should continue after awaiting stale auto-sync: \(outcome.message)")
      }
      XCTAssertEqual(store.drafts.first?.title, "Remote Auto Sync Race")
      let requestsAfterResolution = await transport.capturedRequests()
      XCTAssertEqual(requestsAfterResolution.count, 2)
      XCTAssertNil(store.remoteRepositoryConflictSession)
    }
  #endif

  func testPartialReviewFailureKeepsDraftAndSessionThenRetryCreatesPullRequest() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ConflictResolutionRemoteFailure")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let tokenStore = repositoryTokenStoreForTest()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "ConflictResolutionRemoteFailure"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: RepositoryProvider.github.defaultBaseURL,
        defaultBranch: "main",
        canRead: true,
        canWrite: true,
        message: "Writable"
      )
    )

    let path = "content/posts/failure.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Local Failure",
      slug: "failure",
      draft: false,
      bodyMarkdown:
        "This local article remains unchanged when the remote review request cannot be created.",
      status: .ready,
      repositoryPath: path
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: path,
      remoteRevision: "old-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshBatchPublishPlan()
    let plan = try XCTUnwrap(store.batchPublishPlan)
    let package = try XCTUnwrap(store.remotePublishPackage(for: plan))
    let localDocument = try XCTUnwrap(package.markdownFile?.content)
    let mergedDocument = localDocument.replacingOccurrences(
      of: "Local Failure",
      with: "Reviewed Merge"
    )
    let remoteDocument = localDocument.replacingOccurrences(
      of: "Local Failure",
      with: "Remote Failure"
    )
    let currentResponse = workbenchRemoteResponse(
      json:
        #"{"sha":"new-sha","content":"\#(Data(remoteDocument.utf8).base64EncodedString())","encoding":"base64"}"#
    )
    let baseResponse = workbenchRemoteResponse(
      json:
        #"{"sha":"old-sha","content":"\#(Data(localDocument.utf8).base64EncodedString())","encoding":"base64"}"#
    )
    let mergedBlobSHA = RemoteRepositoryPublishService().gitBlobSHA(
      for: Data(mergedDocument.utf8)
    )
    await transport.replaceResponses([
      currentResponse,
      baseResponse,
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"ref":"refs/heads/publish/conflict-retry","object":{"sha":"target-sha"}}"#
      ),
      workbenchRemoteResponse(json: #"{"sha":"new-sha"}"#),
      workbenchRemoteResponse(
        json: #"{"content":{"sha":"merged-file-sha"},"commit":{"sha":"written-commit"}}"#
      ),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"pull request failed"}"#),
      currentResponse,
      baseResponse,
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-sha"}}"#),
      workbenchRemoteResponse(statusCode: 422, json: #"{"message":"Reference already exists"}"#),
      workbenchRemoteResponse(json: "{\"sha\":\"\(mergedBlobSHA)\"}"),
      workbenchRemoteResponse(json: #"[]"#),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/44"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"written-commit"}}"#),
    ])
    let session = RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: RemoteRepositoryPublishService()
        .conflictPackageFingerprint(package: package, profile: profile),
      publishScope: .batch(plan.remotePublishableItems.map(\.draftID)),
      conflicts: [
        RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old-sha",
          actualSHA: "new-sha",
          base: .text(localDocument),
          local: .text(localDocument),
          remote: .text(remoteDocument)
        )
      ]
    )
    store.publishingStore.remoteRepositoryConflictSession = session
    let originalDrafts = store.drafts

    let resolutionPlan = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [
        .init(
          repositoryPath: path,
          choice: .merge,
          mergedDocument: mergedDocument
        )
      ]
    )
    let firstOutcome = await store.resolveRemoteRepositoryConflicts(
      plan: resolutionPlan
    )

    guard case .failed = firstOutcome else {
      return XCTFail("A partial PR failure must keep the resolution retryable")
    }
    XCTAssertEqual(store.drafts, originalDrafts)
    XCTAssertEqual(store.remoteRepositoryConflictSession, session)
    var requests = await transport.capturedRequests()
    XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/pulls") == true }.count, 1)

    let retryOutcome = await store.resolveRemoteRepositoryConflicts(
      plan: RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          .init(
            repositoryPath: path,
            choice: .merge,
            mergedDocument: mergedDocument
          )
        ]
      )
    )

    guard case .completed = retryOutcome else {
      return XCTFail("The retry must create the missing PR before applying drafts")
    }
    XCTAssertEqual(store.drafts.first?.title, "Reviewed Merge")
    XCTAssertEqual(store.drafts.first?.repositorySyncState(for: profile), .awaitingReview)
    XCTAssertNil(store.remoteRepositoryConflictSession)
    XCTAssertEqual(store.remoteRepositoryPublishResult?.reviewURL, "https://github.com/owner/site/pull/44")
    requests = await transport.capturedRequests()
    XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/pulls") == true }.count, 2)
  }

  func testEditDuringRemoteRevalidationIsPreservedAndStopsBeforeRemoteWrite() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ConflictResolutionLocalRace")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let tokenStore = repositoryTokenStoreForTest()
    let remoteDocument = "---\ntitle: Remote\ndraft: false\n---\n\nRemote body"
    let suspendedTransport = SuspendedWorkbenchRemoteRepositoryTransport(
      response: workbenchRemoteResponse(
        json:
          #"{"sha":"new-sha","content":"\#(Data(remoteDocument.utf8).base64EncodedString())","encoding":"base64"}"#
      )
    )
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "ConflictResolutionLocalRace"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(
        transport: suspendedTransport
      ),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let path = "content/posts/race.md"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Local Race",
      slug: "race",
      draft: false,
      bodyMarkdown:
        "This body is the reviewed local version before the suspended remote revalidation.",
      status: .ready,
      repositoryPath: path
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: path,
      remoteRevision: "old-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshBatchPublishPlan()
    let batchPlan = try XCTUnwrap(store.batchPublishPlan)
    let package = try XCTUnwrap(store.remotePublishPackage(for: batchPlan))
    let localDocument = try XCTUnwrap(package.markdownFile?.content)
    let session = RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: RemoteRepositoryPublishService()
        .conflictPackageFingerprint(package: package, profile: profile),
      publishScope: .batch(batchPlan.remotePublishableItems.map(\.draftID)),
      conflicts: [
        RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old-sha",
          actualSHA: "new-sha",
          base: .text(localDocument),
          local: .text(localDocument),
          remote: .text(remoteDocument)
        )
      ]
    )
    store.publishingStore.remoteRepositoryConflictSession = session

    let resolutionTask = Task { @MainActor in
      await store.resolveRemoteRepositoryConflicts(
        plan: RemoteRepositoryConflictResolutionPlan(
          sessionID: session.id,
          decisions: [
            .init(repositoryPath: path, choice: .useRemote)
          ]
        )
      )
    }
    await suspendedTransport.waitUntilRequestArrives()
    var editedDraft = try XCTUnwrap(store.drafts.first)
    editedDraft.bodyMarkdown = "A new local edit made while the remote request was suspended."
    store.setDrafts([editedDraft])
    await suspendedTransport.resume()
    let outcome = await resolutionTask.value

    guard case .sessionInvalidated = outcome else {
      return XCTFail("The local edit must invalidate the reviewed transaction: \(outcome.message)")
    }
    let requestCount = await suspendedTransport.requestCount()
    XCTAssertEqual(store.drafts.first?.bodyMarkdown, editedDraft.bodyMarkdown)
    XCTAssertEqual(requestCount, 2)
    XCTAssertNil(store.remoteRepositoryConflictSession)
  }

  private func conflictSession(
    profile: SiteProfile,
    draftIDs: [UUID]
  ) -> RemoteRepositoryConflictSession {
    let paths = ["content/posts/first.md", "content/posts/second.md"]
    return RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: "frozen-package",
      publishScope: .batch(draftIDs),
      conflicts: paths.enumerated().map { index, path in
        RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old-\(index)",
          actualSHA: "new-\(index)",
          base: .text("base \(index)"),
          local: .text("local \(index)"),
          remote: .text("remote \(index)")
        )
      }
    )
  }
}
