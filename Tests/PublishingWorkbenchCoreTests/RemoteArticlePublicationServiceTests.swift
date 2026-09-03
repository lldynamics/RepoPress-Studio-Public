import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteArticlePublicationServiceTests: XCTestCase {
  func testPublishRunsMutationHookForWriteButNotForRemoteReads() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json: #"{"content":{"sha":"uploaded"},"commit":{"sha":"commit-sha"}}"#),
    ])
    let counter = RemoteArticleMutationHookCounter()
    let package = remoteArticlePackage(content: "# Article")

    _ = try await RemoteRepositoryPublishService(transport: transport).publish(
      package: package,
      profile: remoteArticleProfile(),
      mode: .directCommit,
      token: "test-token",
      beforeMutation: {
        await counter.recordCall()
      }
    )

    let callCount = await counter.callCount()
    let requests = await transport.capturedRequests()
    XCTAssertEqual(callCount, 1)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
  }

  func
    testPublishRejectsChangedAttachmentPayloadBeforeUploadEvenIfMutationGuardRestoresReviewedBytes()
    async throws
  {
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-article-payload-binding-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    let reviewedBytes = Data([0x01, 0x02, 0x03, 0x04])
    let changedBytes = Data([0x05, 0x06, 0x07, 0x08])
    try reviewedBytes.write(to: sourceURL)

    let attachment = PublishPackageFile(
      kind: .image,
      repositoryPath: "static/cover.bin",
      sourceFilePath: sourceURL.path,
      byteSize: Int64(reviewedBytes.count)
    )
    var package = remoteArticlePackage(content: "# Article")
    package.files.append(attachment)
    let digestService = RemoteRepositoryPublishService()
    let expectedContentSHA256 = [
      package.files[0].repositoryPath: try XCTUnwrap(
        digestService.contentSHA256(for: package.files[0])),
      attachment.repositoryPath: try XCTUnwrap(digestService.contentSHA256(for: attachment)),
    ]
    let unchangedMarkdownSHA = digestService.gitBlobSHA(for: Data("# Article".utf8))

    // This reproduces the stale-guard ordering: an older guard could restore
    // A immediately before the request while a payload assembled from B was
    // already queued. The payload digest must reject B before any upload.
    try changedBytes.write(to: sourceURL)
    let mutationCounter = RemoteArticleMutationHookCounter()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"target-head","tree":{"sha":"target-tree"},"parents":[]}"#
      ),
      workbenchRemoteResponse(json: #"{"sha":"\#(unchangedMarkdownSHA)"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
    ])

    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).publish(
        package: package,
        profile: remoteArticleProfile(),
        mode: .directCommit,
        token: "test-token",
        expectedContentSHA256: expectedContentSHA256,
        beforeMutation: {
          await mutationCounter.recordCall()
          try reviewedBytes.write(to: sourceURL)
        }
      )
      XCTFail("Changed attachment bytes must invalidate the reviewed payload")
    } catch let error as RemoteArticlePublicationReviewError {
      XCTAssertEqual(error, .confirmationExpired)
    }

    let mutationCalls = await mutationCounter.callCount()
    let requests = await transport.capturedRequests()
    XCTAssertEqual(mutationCalls, 0)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
  }

  func testRemoteReviewTreatsMissingTargetFileAsAddedEvenWhenLocalBytesAreAlreadySaved()
    async throws
  {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let profile = remoteArticleProfile()
    let package = remoteArticlePackage(
      content: "# Remote article\n\nSaved locally, absent remotely.")

    let review = try await service.reviewRemoteArticlePublication(
      package: package,
      profile: profile,
      mode: .directCommit,
      token: "test-token"
    )

    XCTAssertEqual(review.targetBranchVersion, "target-head")
    XCTAssertEqual(review.files.map(\.status), [.added])
    XCTAssertEqual(review.changedPaths, [package.markdownPath])
    XCTAssertFalse(review.isFullySynchronized)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
    XCTAssertEqual(requests[1].url?.query?.removingPercentEncoding, "ref=target-head")
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
  }

  func testRemoteReviewTreatsIdenticalTargetFileAsSynchronizedWithoutWrite() async throws {
    let content = "# Remote article\n\nThe exact same bytes."
    let remoteSHA = RemoteRepositoryPublishService().gitBlobSHA(for: Data(content.utf8))
    let encoded = Data(content.utf8).base64EncodedString()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"\#(remoteSHA)","content":"\#(encoded)","encoding":"base64"}"#
      ),
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let package = remoteArticlePackage(content: content)

    let review = try await service.reviewRemoteArticlePublication(
      package: package,
      profile: remoteArticleProfile(),
      mode: .directCommit,
      token: "test-token"
    )

    XCTAssertEqual(review.files.map(\.status), [.unchanged])
    XCTAssertTrue(review.isFullySynchronized)
    XCTAssertTrue(review.changedPaths.isEmpty)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
  }

  @MainActor
  func testReviewBindingRejectsBodyTargetAndRemoteBaselineDrift() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let package = remoteArticlePackage(content: "# One\n\nOriginal")
    let profile = remoteArticleProfile()
    let expected = remoteArticleReview(package: package, profile: profile)

    var editedPackage = package
    editedPackage.files[0].content = "# One\n\nEdited"
    XCTAssertFalse(
      store.publishingStore.remoteArticlePackageMatches(expected.package, editedPackage))

    var targetChanged = expected
    targetChanged.target.targetBranch = "release"
    XCTAssertFalse(store.publishingStore.remoteArticleReviewMatches(expected, targetChanged))

    var remoteChanged = expected
    remoteChanged.targetBranchVersion = "new-target-head"
    remoteChanged.files[0].remoteVersion = "new-file-version"
    XCTAssertFalse(store.publishingStore.remoteArticleReviewMatches(expected, remoteChanged))
  }

  @MainActor
  func testConfirmedSynchronizedArticleDoesNotIssueRemoteWrite() async throws {
    let tokenStore = KeychainTokenStore(
      service: "RemoteArticlePublicationTests.\(UUID().uuidString)",
      accountPrefix: "remote-article-test",
      inMemory: true
    )
    let profile = remoteArticleProfile()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("test-token", for: profile)
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: profile.repositoryDisplayName,
        apiBaseURL: profile.repositoryBaseURL,
        defaultBranch: "main",
        targetBranch: "main",
        publishStrategy: .direct,
        canRead: true,
        canWrite: true,
        message: "Writable"
      )
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Already synchronized",
      slug: "already-synchronized",
      draft: false,
      bodyMarkdown:
        "This body is long enough to make a normal publish package for the remote sync test."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    let package = store.publishingPackage(for: draft)
    let content = try XCTUnwrap(package.markdownFile?.content)
    let sha = RemoteRepositoryPublishService().gitBlobSHA(for: Data(content.utf8))
    let remotePayload = Data(content.utf8).base64EncodedString()
    await transport.replaceResponses([
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"\#(sha)","content":"\#(remotePayload)","encoding":"base64"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"\#(sha)","content":"\#(remotePayload)","encoding":"base64"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
    ])

    let reviewed = await store.reviewRemoteArticlePublication(for: draft)
    let review = try XCTUnwrap(reviewed)
    let result = await store.publishReviewedRemoteArticlePublication(review)

    XCTAssertNil(result)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET", "GET", "GET"])
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
    XCTAssertTrue(store.publishActionMessage?.contains("未重复写入") == true)
  }

  func testRemoteReviewRejectsTargetHeadThatMovesDuringReadOnlyInspection() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"target-head"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"moved-head"}}"#),
    ])

    do {
      _ = try await RemoteRepositoryPublishService(transport: transport)
        .reviewRemoteArticlePublication(
          package: remoteArticlePackage(content: "# Article"),
          profile: remoteArticleProfile(),
          mode: .reviewRequest,
          token: "test-token"
        )
      XCTFail("A moving target branch must invalidate the review")
    } catch let error as RemoteArticlePublicationReviewError {
      XCTAssertEqual(error, .remoteChanged)
    }

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
  }

  @MainActor
  func testAttachmentByteChangeInvalidatesReviewWhenPathAndSizeRemainStable() throws {
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-article-attachment-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    try Data([0x01, 0x02, 0x03, 0x04]).write(to: sourceURL)

    let attachment = PublishPackageFile(
      kind: .image,
      repositoryPath: "static/cover.bin",
      sourceFilePath: sourceURL.path,
      byteSize: 4
    )
    var package = remoteArticlePackage(content: "# Article")
    package.files.append(attachment)
    let service = RemoteRepositoryPublishService()
    let attachmentDigest = try XCTUnwrap(service.contentSHA256(for: attachment))
    let review = RemoteArticlePublicationReview(
      package: package,
      target: RemoteRepositoryPublishTargetSnapshot(
        profile: remoteArticleProfile(),
        preview: RemoteRepositoryPublishPreview(
          provider: .github,
          repositoryName: "owner/site",
          mode: .reviewRequest,
          branchName: "publish/remote-article",
          targetBranch: "main",
          changedPaths: package.files.map(\.repositoryPath),
          hasToken: true,
          blockingIssues: [],
          warningIssues: []
        )
      ),
      targetBranchVersion: "target-head",
      files: [
        .init(
          path: package.markdownPath, kind: .markdown, operation: .upsert, status: .modified,
          byteSize: 0, contentSHA256: try service.contentSHA256(for: package.files[0]),
          remoteVersion: "article-version"),
        .init(
          path: attachment.repositoryPath, kind: .image, operation: .upsert, status: .modified,
          byteSize: 4, contentSHA256: attachmentDigest, remoteVersion: "attachment-version"),
      ]
    )

    try Data([0x05, 0x06, 0x07, 0x08]).write(to: sourceURL)
    let store = try TestWorkbenchFactory.makeStore()
    XCTAssertTrue(store.publishingStore.remoteArticlePackageMatches(review.package, package))
    XCTAssertFalse(
      try store.publishingStore.remoteArticlePackageContentMatches(review, package: package))
  }

  private func remoteArticleProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    return profile
  }

  private func remoteArticlePackage(content: String) -> PublishPackage {
    PublishPackage(
      draftID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
      title: "Remote article",
      markdownPath: "content/posts/remote-article.md",
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/remote-article.md",
          content: content
        )
      ],
      commitMessage: "Publish remote article",
      reviewBranchName: "publish/remote-article",
      reviewTitle: "Publish remote article",
      reviewChecklist: []
    )
  }

  private func remoteArticleReview(
    package: PublishPackage,
    profile: SiteProfile
  ) -> RemoteArticlePublicationReview {
    let preview = RemoteRepositoryPublishPreview(
      provider: .github,
      repositoryName: profile.repositoryDisplayName,
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: package.files.map(\.repositoryPath),
      hasToken: true,
      blockingIssues: [],
      warningIssues: []
    )
    return RemoteArticlePublicationReview(
      package: package,
      target: RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview),
      targetBranchVersion: "target-head",
      files: [
        .init(
          path: package.markdownPath,
          kind: .markdown,
          operation: .upsert,
          status: .modified,
          byteSize: 0,
          remoteVersion: "file-version",
          lineDiff: "-Original\n+Edited"
        )
      ]
    )
  }
}

private actor RemoteArticleMutationHookCounter {
  private var calls = 0

  func recordCall() {
    calls += 1
  }

  func callCount() -> Int {
    calls
  }
}
