import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchSinglePublishReviewTests: WorkbenchStoreRemotePublishingTestCase {
  func testSingleReviewRejectsChangedBodyMetadataTargetAndSelectionBeforeNetwork() async throws {
    for mutation in ["body", "title", "branch", "mode", "selection"] {
      let root = try preparedGitRepositoryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let transport = CountingRemoteRepositoryTransport()
      let tokenStore = repositoryTokenStoreForTest()
      let store = WorkbenchStore(
        persistence: try TestWorkbenchFactory.persistence(),
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
      profile.rememberLocalRepositoryRoot(root)
      store.updateActiveProfile(profile)
      try tokenStore.saveRepositoryToken("test-only-token", for: profile)
      store.refreshRepositoryTokenAvailability()
      var draft = ArticleDraft(
        siteProfileID: profile.id, title: "Reviewed article", slug: "reviewed-article",
        draft: false,
        bodyMarkdown:
          "The original article is long enough to pass preflight checks and open the single article review."
      )
      store.setDrafts([draft])
      store.setSelectedDraftID(draft.id)
      store.refreshPublishPreview(for: draft)
      let snapshot = try XCTUnwrap(store.cachedDraftPublishPreviewSnapshot(for: draft.id))
      let review = try SinglePublishReviewExpectation(
        package: snapshot.publishPackage, profile: profile, preview: snapshot.remotePublishPreview)
      XCTAssertTrue(
        review.matches(
          package: snapshot.publishPackage, profile: profile, preview: snapshot.remotePublishPreview
        ))
      switch mutation {
      case "body":
        draft.bodyMarkdown += "\n\nUnreviewed text."
        store.setDrafts([draft])
      case "title":
        draft.title = "Unreviewed title"
        store.setDrafts([draft])
      case "branch":
        profile.branch = "different-target"
        store.updateActiveProfile(profile)
      case "mode":
        profile.repositoryPublishStrategy = .reviewRequest
        store.updateActiveProfile(profile)
      default: store.createDraft()
      }
      let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy(
        expectedReview: review)
      let requests = await transport.requestCount()
      XCTAssertNil(result, mutation)
      XCTAssertEqual(requests, 0, mutation)
      XCTAssertTrue(store.publishActionMessage?.contains("重新打开确认页审阅") == true, mutation)
    }
  }

  func testSingleReviewRevalidatesAfterPermissionRequestSuspends() async throws {
    let root = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = ReviewMutationTransport()
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
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
    profile.rememberLocalRepositoryRoot(root)
    store.updateActiveProfile(profile)
    try tokenStore.saveRepositoryToken("test-only-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    let draft = ArticleDraft(
      siteProfileID: profile.id, title: "Permission suspension", slug: "permission-suspension",
      draft: false,
      bodyMarkdown:
        "An article long enough for preflight to permit the initial read-only repository permission request."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshPublishPreview(for: draft)
    let snapshot = try XCTUnwrap(store.cachedDraftPublishPreviewSnapshot(for: draft.id))
    let review = try SinglePublishReviewExpectation(
      package: snapshot.publishPackage, profile: profile, preview: snapshot.remotePublishPreview)
    await transport.install {
      var changed = draft
      changed.bodyMarkdown += "\nChanged while checking access."
      store.setDrafts([changed])
    }
    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy(
      expectedReview: review)
    let methods = await transport.methods
    XCTAssertNil(result)
    XCTAssertEqual(
      methods, ["GET"], "Permission lookup runs, but changed content must never reach a write")
    XCTAssertTrue(
      store.publishActionMessage?.contains("重新打开确认页审阅") == true,
      store.publishActionMessage ?? "No feedback")
  }

  func testReviewDetectsChangedAttachmentBytesAtSamePath() throws {
    let root = try temporaryDirectoryURL(prefix: "single-review-media")
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("image.png")
    try Data([1, 2, 3]).write(to: media)
    let store = try TestWorkbenchFactory.makeStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    var package = store.publishingPackage(for: draft)
    package.files.append(
      PublishPackageFile(
        kind: .image, repositoryPath: "static/images/image.png", sourceFilePath: media.path,
        byteSize: 3))
    store.refreshPublishPreview(for: draft)
    let preview = try XCTUnwrap(store.cachedRemotePublishPreview(for: draft))
    let review = try SinglePublishReviewExpectation(
      package: package, profile: store.activeProfile, preview: preview)
    let bound = review.bindingMediaContent(in: package)
    let service = RemoteRepositoryPublishService(transport: CountingRemoteRepositoryTransport())
    XCTAssertEqual(try service.contentData(for: XCTUnwrap(bound.files.last)), Data([1, 2, 3]))
    // Same path and byte length must not hide replacement of the reviewed image.
    try Data([4, 5, 6]).write(to: media)
    XCTAssertFalse(review.matches(package: package, profile: store.activeProfile, preview: preview))
    XCTAssertThrowsError(try service.contentData(for: XCTUnwrap(bound.files.last)))
  }
}

private actor ReviewMutationTransport: RemoteRepositoryHTTPTransport {
  private var mutation: (@MainActor @Sendable () -> Void)?
  private(set) var methods: [String] = []

  func install(_ mutation: @escaping @MainActor @Sendable () -> Void) { self.mutation = mutation }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    methods.append(request.httpMethod ?? "GET")
    if let mutation {
      self.mutation = nil
      await mutation()
    }
    let data = Data(
      #"{"full_name":"owner/site","default_branch":"main","permissions":{"pull":true,"push":true}}"#
        .utf8)
    return (
      data,
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}
