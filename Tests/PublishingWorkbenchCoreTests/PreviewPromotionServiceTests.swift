import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class PreviewPromotionServiceTests: XCTestCase {
  func testPrepareReadsOnlyExactPreviewAndKeepsOriginalRecord() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: previewResponses())
    let plan = try await RemoteRepositoryPublishService(transport: transport)
      .preparePreviewPromotion(
        record: record(), profile: profile(), token: "test")
    XCTAssertEqual(plan.files.map(\.path), [articlePath])
    XCTAssertEqual(plan.markdown, document)
    XCTAssertEqual(plan.sourceCommitSHA, "head")
    XCTAssertEqual(plan.record.kind, .remotePreviewBranch)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertTrue(requests.last?.url?.absoluteString.contains("ref=head") == true)
  }

  func testChangedPreviewHeadStopsBeforeComparison() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [ref("new-head")])
    await assertFailure {
      _ = try await RemoteRepositoryPublishService(transport: transport).preparePreviewPromotion(
        record: self.record(), profile: self.profile(), token: "test")
    }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testLegacyNoOpPreviewCanBeReadAndCreatesReceiptBoundToReviewedHead() async throws {
    var legacy = record()
    legacy.commitSHA = nil
    legacy.changedPaths = []
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: previewResponses() + previewResponses() + [
        response(#"[{"number":7,"html_url":"https://github.com/owner/site/pull/7"}]"#)
      ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let plan = try await service.preparePreviewPromotion(
      record: legacy, profile: profile(), token: "test")
    XCTAssertNil(plan.record.commitSHA)
    XCTAssertEqual(plan.sourceCommitSHA, "head")
    let review = try await service.createReviewForPreview(plan: plan, token: "test")
    XCTAssertEqual(review.commitSHA, "head")
    XCTAssertEqual(review.previewSourceRecordID, legacy.id)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testLegacyPreviewHeadChangeAfterReviewCannotCreatePR() async throws {
    var plan = previewPlan()
    var legacy = plan.record
    legacy.commitSHA = nil
    plan = PreviewPromotionPlan(
      record: legacy, profile: plan.profile, sourceCommitSHA: plan.sourceCommitSHA,
      targetCommitSHA: plan.targetCommitSHA, files: plan.files, markdown: plan.markdown,
      checkedAt: plan.checkedAt)
    var responses = previewResponses()
    responses[0] = ref("changed-head")
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: responses)
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).createReviewForPreview(
        plan: plan, token: "test")
      XCTFail("A legacy record must still bind the user confirmation to a fixed head")
    } catch {
      XCTAssertEqual(error as? PreviewPromotionError, .changed)
    }
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testRejectsOtherArticlesDeletionRenameAndProtectedPathsWithoutMutation() async throws {
    for change in [
      changeJSON(path: "content/posts/other.md"), changeJSON(status: "removed"),
      changeJSON(status: "renamed"), changeJSON(path: "content/posts/_index.md"),
    ] {
      let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
        ref("head"), ref("base"), response("{\"files\":[\(change)]}"),
      ])
      await assertFailure {
        _ = try await RemoteRepositoryPublishService(transport: transport).preparePreviewPromotion(
          record: self.record(), profile: self.profile(), token: "test")
      }
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testRejectsTruncatedFileListAndPrivateOrWebsiteDraftSource() async throws {
    let tooMany = Array(repeating: changeJSON(), count: 300).joined(separator: ",")
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      ref("head"), ref("base"), response("{\"files\":[\(tooMany)]}"),
    ])
    await assertFailure {
      _ = try await RemoteRepositoryPublishService(transport: transport).preparePreviewPromotion(
        record: self.record(), profile: self.profile(), token: "test")
    }
    for source in [
      document.replacingOccurrences(of: "draft = false", with: "draft = true"),
      document.replacingOccurrences(of: "draft = false", with: "visibility = \"private\""),
    ] {
      let fixture = SequencedWorkbenchRemoteRepositoryTransport(
        responses: previewResponses(document: source))
      await assertFailure {
        _ = try await RemoteRepositoryPublishService(transport: fixture).preparePreviewPromotion(
          record: self.record(), profile: self.profile(), token: "test")
      }
    }
  }

  func testCreateReusesExistingPRAndPreservesPreviewIdentity() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: previewResponses() + [
        response(#"[{"number":7,"html_url":"https://github.com/owner/site/pull/7"}]"#)
      ])
    let review = try await RemoteRepositoryPublishService(transport: transport)
      .createReviewForPreview(plan: previewPlan(), token: "test")
    XCTAssertEqual(review.kind, .remoteReviewRequest)
    XCTAssertEqual(review.previewSourceRecordID, record().id)
    XCTAssertNotEqual(review.id, record().id)
    XCTAssertEqual(review.reviewNumber, 7)
    XCTAssertNil(review.deploymentCommitSHA)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testCreatedReviewReturnsReceiptWithoutDependingOnAnotherNetworkRead() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: previewResponses() + [
        response("[]"),
        response(#"{"number":7,"html_url":"https://github.com/owner/site/pull/7"}"#),
      ])
    let review = try await RemoteRepositoryPublishService(transport: transport)
      .createReviewForPreview(
        plan: previewPlan(), token: "test")
    XCTAssertEqual(review.reviewNumber, 7)
    XCTAssertEqual(review.previewSourceRecordID, record().id)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 6)
    XCTAssertEqual(requests.last?.httpMethod, "POST")
    XCTAssertNil(review.reviewStatus)
  }

  func testCreateStopsAtMutationBoundaryWhenAuthorizationExpires() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: previewResponses() + [response("[]")])
    await assertFailure {
      _ = try await RemoteRepositoryPublishService(transport: transport).createReviewForPreview(
        plan: self.previewPlan(), token: "test",
        beforeMutation: {
          throw PreviewPromotionError.changed
        })
    }
    let requests = await transport.capturedRequests()
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
  }

  func testMergeChecksThenWritesReviewedSHAAndTracksMergeCommit() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: mergeResponses() + mergeResponses() + [
        response(#"{"merged":true,"sha":"merged-head","message":"merged"}"#)
      ])
    let service = RemoteRepositoryPublishService(transport: transport)
    let plan = try await service.prepareReviewMerge(
      record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
    XCTAssertTrue(plan.canMerge)
    let merged = try await service.mergeReviewedPublication(plan: plan, token: "test")
    XCTAssertEqual(merged.commitSHA, "head")
    XCTAssertEqual(merged.deploymentCommitSHA, "merged-head")
    let writes = await transport.capturedRequests().filter { $0.httpMethod != "GET" }
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.first?.httpMethod, "PUT")
    let body = try XCTUnwrap(writes.first?.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    XCTAssertEqual(payload, ["sha": "head"])
  }

  func testFailedChecksBlockMergeWithoutWrite() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: mergeResponses(
        checks:
          #"{"total_count":1,"check_runs":[{"name":"Build","status":"completed","conclusion":"failure"}]}"#
      ))
    let service = RemoteRepositoryPublishService(transport: transport)
    let plan = try await service.prepareReviewMerge(
      record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
    XCTAssertFalse(plan.canMerge)
    XCTAssertTrue(plan.blockers.contains { $0.contains("Build") })
    await assertFailure {
      _ = try await service.mergeReviewedPublication(plan: plan, token: "test")
    }
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testDeniedCheckReadsIdentifyExactReadPermissionWithoutAnonymousFallback() async throws {
    for (index, permission, endpoint) in [
      (4, GitHubReviewCheckPermission.checks, "/check-runs"),
      (5, GitHubReviewCheckPermission.commitStatuses, "/status"),
    ] {
      let transport = SequencedWorkbenchRemoteRepositoryTransport(
        responses: Array(mergeResponses().prefix(index)) + [permissionDeniedResponse()])
      let service = RemoteRepositoryPublishService(transport: transport)
      do {
        _ = try await service.prepareReviewMerge(
          record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
        XCTFail("A denied check read must not produce a merge plan")
      } catch let RemoteRepositoryPublishError.reviewCheckPermissionDenied(actual, body) {
        XCTAssertEqual(actual, permission)
        XCTAssertTrue(body.contains("Resource not accessible by personal access token"))
        let message = RemoteRepositoryPublishError.reviewCheckPermissionDenied(
          permission: actual, body: body
        ).localizedDescription
        XCTAssertTrue(message.contains(permission.requiredPermission))
        XCTAssertFalse(message.contains("GitLab"))
      }
      let requests = await transport.capturedRequests()
      XCTAssertEqual(requests.count, index + 1)
      XCTAssertTrue(requests.last?.url?.path.hasSuffix(endpoint) == true)
      XCTAssertTrue(
        requests.allSatisfy {
          $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test"
        })
    }
  }

  func testPermissionLostDuringFinalMergeCheckStopsBeforePUT() async throws {
    for (index, permission) in [(4, GitHubReviewCheckPermission.checks), (5, .commitStatuses)] {
      let transport = SequencedWorkbenchRemoteRepositoryTransport(
        responses: mergeResponses() + Array(mergeResponses().prefix(index)) + [
          permissionDeniedResponse()
        ])
      let service = RemoteRepositoryPublishService(transport: transport)
      let plan = try await service.prepareReviewMerge(
        record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
      XCTAssertTrue(plan.canMerge)
      do {
        _ = try await service.mergeReviewedPublication(plan: plan, token: "test")
        XCTFail("A previously passing plan cannot bypass lost read permission")
      } catch let RemoteRepositoryPublishError.reviewCheckPermissionDenied(actual, _) {
        XCTAssertEqual(actual, permission)
      }
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testRetryAfterPermissionRepairRechecksSamePRWithoutCreatingOrMergingIt() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: Array(mergeResponses().prefix(4)) + [permissionDeniedResponse()] + mergeResponses()
    )
    let service = RemoteRepositoryPublishService(transport: transport)
    let reviewRecord = record(kind: .remoteReviewRequest)
    await assertFailure {
      _ = try await service.prepareReviewMerge(
        record: reviewRecord, profile: self.profile(), token: "test")
    }
    let plan = try await service.prepareReviewMerge(
      record: reviewRecord, profile: profile(), token: "test")
    XCTAssertTrue(plan.canMerge)
    XCTAssertEqual(plan.record.id, reviewRecord.id)
    XCTAssertEqual(plan.record.reviewNumber, 7)
    XCTAssertEqual(plan.sourceCommitSHA, "head")
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/check-runs") == true }.count, 2)
  }

  func testCheckReadRateLimitsAndServerFailuresAreNotMisclassifiedAsMissingTokenPermission()
    async throws
  {
    for (status, body) in [
      (403, #"{"message":"API rate limit exceeded"}"#), (500, #"{"message":"Server error"}"#),
    ] {
      let transport = SequencedWorkbenchRemoteRepositoryTransport(
        responses: Array(mergeResponses().prefix(4)) + [
          workbenchRemoteResponse(statusCode: status, json: body)
        ])
      do {
        _ = try await RemoteRepositoryPublishService(transport: transport).prepareReviewMerge(
          record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
        XCTFail("A failed read must stop preparation")
      } catch let RemoteRepositoryPublishError.httpStatus(actual, detail) {
        XCTAssertEqual(actual, status)
        XCTAssertTrue(detail.contains(status == 403 ? "rate limit" : "Server error"))
      }
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testCheckReadPermissionErrorKeepsTokenRedacted() async throws {
    let token = "sensitive-test-token-keep-private"
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: Array(mergeResponses().prefix(4)) + [
        workbenchRemoteResponse(
          statusCode: 403,
          json:
            "{\"message\":\"Resource not accessible by personal access token\",\"echo\":\"\(token)\"}"
        )
      ])
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).prepareReviewMerge(
        record: record(kind: .remoteReviewRequest), profile: profile(), token: token)
      XCTFail("A denied check read must stop preparation")
    } catch let RemoteRepositoryPublishError.reviewCheckPermissionDenied(permission, body) {
      XCTAssertEqual(permission, .checks)
      XCTAssertFalse(body.contains(token))
      XCTAssertFalse(
        RemoteRepositoryPublishError.reviewCheckPermissionDenied(permission: permission, body: body)
          .localizedDescription.contains(token))
    }
  }

  func testBaseMovingDuringFinalInspectionStopsMergeWithoutWrite() async throws {
    var changed = mergeResponses()
    changed[changed.count - 1] = ref("new-base")
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: mergeResponses() + changed)
    let service = RemoteRepositoryPublishService(transport: transport)
    let plan = try await service.prepareReviewMerge(
      record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
    do {
      _ = try await service.mergeReviewedPublication(plan: plan, token: "test")
      XCTFail("A moving base must require another review")
    } catch {
      XCTAssertEqual(error as? PreviewPromotionError, .changed)
    }
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testLostAuthorizationAtMergeBoundaryStopsPUT() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: mergeResponses() + mergeResponses())
    let service = RemoteRepositoryPublishService(transport: transport)
    let plan = try await service.prepareReviewMerge(
      record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
    do {
      _ = try await service.mergeReviewedPublication(
        plan: plan, token: "test",
        beforeMutation: {
          throw PreviewPromotionError.changed
        })
      XCTFail("Revoked authorization must stop the merge")
    } catch {
      XCTAssertEqual(error as? PreviewPromotionError, .changed)
    }
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testAlreadyMergedRetryOnlyReadsAndReturnsExistingCommit() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      pullStatus(merged: true)
    ])
    let plan = try await RemoteRepositoryPublishService(transport: transport).prepareReviewMerge(
      record: record(kind: .remoteReviewRequest), profile: profile(), token: "test")
    XCTAssertEqual(plan.mergedCommitSHA, "merged-head")
    XCTAssertFalse(plan.canMerge)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.httpMethod, "GET")
  }

  func testRecordLinkDecodesOldHistoryAndRoundTripsNewHistory() throws {
    var value = record(kind: .remoteReviewRequest)
    value.previewSourceRecordID = UUID()
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(
      try JSONDecoder().decode(ReleaseRecord.self, from: data).previewSourceRecordID,
      value.previewSourceRecordID)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "previewSourceRecordID")
    let oldData = try JSONSerialization.data(withJSONObject: legacy)
    XCTAssertNil(try JSONDecoder().decode(ReleaseRecord.self, from: oldData).previewSourceRecordID)
  }

  func testStrictFrontMatterRejectsCommentedPrivateFlagsAndDuplicateOverrides() throws {
    for metadata in [
      "+++\ndraft = true # not ready\n+++", "---\nprivate: true # secret\n---",
      "+++\ndraft = true\n[extra]\ndraft = false\n+++", "---\nprivate: true\nprivate: false\n---",
      "---\nvisibility: private # secret\n---", "---\n<<: *privateDefaults\n---",
      "+++\n\"draft\" = true\n+++", "---\npublished: false\n---",
    ] {
      XCTAssertThrowsError(
        try PreviewPromotionFrontMatterPolicy.validatePublicDocument(metadata + "\nBody"))
    }
    XCTAssertNoThrow(
      try PreviewPromotionFrontMatterPolicy.validatePublicDocument(
        "+++\ndraft = false # ready\nvisibility = \"public\" # public\n[extra]\ndraft = true\n+++\nBody"
      ))
  }

  func testHistoryLimitKeepsOldPreviewTogetherWithNewFormalRecord() {
    let preview = record()
    var old = (0..<249).map { index in ReleaseRecord(title: "Old \(index)", summary: "Local") }
    old.append(preview)
    var formal = record(kind: .remoteReviewRequest)
    formal.id = UUID()
    formal.previewSourceRecordID = preview.id
    let retained = ReleaseRecord.limitedHistory([formal] + old)
    XCTAssertEqual(retained.count, 250)
    XCTAssertEqual(retained.first?.id, formal.id)
    XCTAssertTrue(retained.contains { $0.id == preview.id })
    XCTAssertFalse(retained.contains { $0.id == old[248].id })
  }

  @MainActor
  func testLocalWebsiteDraftBlocksPreparingPreviewBeforeNetwork() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let currentProfile = profile()
    var draft = ArticleDraft(
      siteProfileID: currentProfile.id, title: "Article", slug: "article", draft: true,
      bodyMarkdown: "Draft")
    draft.repositoryPath = articlePath
    var preview = record()
    preview.draftID = draft.id
    store.publishingStore.profiles = [currentProfile]
    store.publishingStore.activeProfileID = currentProfile.id
    store.publishingStore.drafts = [draft]
    store.publishingStore.releaseRecords = [preview]
    do {
      _ = try await store.preparePreviewPromotion(for: preview)
      XCTFail("A website draft must not become a production review")
    } catch let error as PreviewPromotionError {
      guard case .unavailable = error else { return XCTFail("Expected the draft safety rejection") }
    }
  }

  private let articlePath = "content/posts/article.md"
  private var document: String {
    "+++\ntitle = \"Article\"\ndate = \"2026-08-31\"\nslug = \"article\"\ndraft = false\n+++\n\n# Article\n\nPreview body.\n"
  }
  private func profile() -> SiteProfile {
    var profile = SiteProfile(name: "Test Site")
    profile.id = UUID(uuidString: "DCD6654B-97A8-4615-85D2-EEA09C32FE63")!
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    return profile
  }
  private func record(kind: ReleaseRecordKind = .remotePreviewBranch) -> ReleaseRecord {
    ReleaseRecord(
      id: UUID(uuidString: "48E0D9C7-37BD-41B2-A7B2-B113739C9509")!, kind: kind,
      title: "Article", summary: "Preview", siteProfileID: profile().id, draftTitle: "Article",
      markdownPath: articlePath, changedPaths: [articlePath], repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com", repoOwner: "owner", repoName: "site",
      branchName: "draft/article", targetBranch: "main", commitSHA: "head",
      reviewNumber: kind == .remoteReviewRequest ? 7 : nil,
      reviewURL: kind == .remoteReviewRequest ? "https://github.com/owner/site/pull/7" : nil)
  }
  private func previewPlan() -> PreviewPromotionPlan {
    PreviewPromotionPlan(
      record: record(), profile: profile(), sourceCommitSHA: "head", targetCommitSHA: "base",
      files: [
        PreviewPromotionFile(
          path: articlePath, status: "added", blobSHA: "blob", additions: 1, deletions: 0,
          patch: "+Article")
      ],
      markdown: document, checkedAt: Date())
  }
  private func changeJSON(path: String? = nil, status: String = "added") -> String {
    "{\"filename\":\"\(path ?? articlePath)\",\"status\":\"\(status)\",\"sha\":\"blob\",\"additions\":1,\"deletions\":0,\"patch\":\"+Article\"}"
  }
  private func response(_ json: String) -> WorkbenchRemoteRepositoryTransportResponse {
    workbenchRemoteResponse(json: json)
  }
  private func permissionDeniedResponse() -> WorkbenchRemoteRepositoryTransportResponse {
    workbenchRemoteResponse(
      statusCode: 403, json: #"{"message":"Resource not accessible by personal access token"}"#)
  }
  private func ref(_ sha: String) -> WorkbenchRemoteRepositoryTransportResponse {
    response("{\"object\":{\"sha\":\"\(sha)\"}}")
  }
  private func content(_ value: String? = nil) -> WorkbenchRemoteRepositoryTransportResponse {
    response(
      "{\"sha\":\"blob\",\"content\":\"\(Data((value ?? document).utf8).base64EncodedString())\",\"encoding\":\"base64\"}"
    )
  }
  private func previewResponses(document: String? = nil)
    -> [WorkbenchRemoteRepositoryTransportResponse]
  {
    [ref("head"), ref("base"), response("{\"files\":[\(changeJSON())]}"), content(document)]
  }
  private func pullStatus(merged: Bool = false) -> WorkbenchRemoteRepositoryTransportResponse {
    response(
      "{\"number\":7,\"state\":\"\(merged ? "closed" : "open")\",\"merged\":\(merged),\"html_url\":\"https://github.com/owner/site/pull/7\",\"merge_commit_sha\":\(merged ? "\"merged-head\"" : "null"),\"head\":{\"ref\":\"draft/article\",\"sha\":\"head\",\"repo\":{\"full_name\":\"owner/site\"}},\"base\":{\"ref\":\"main\",\"sha\":\"base\",\"repo\":{\"full_name\":\"owner/site\"}}}"
    )
  }
  private func mergeResponses(checks: String = #"{"total_count":0,"check_runs":[]}"#)
    -> [WorkbenchRemoteRepositoryTransportResponse]
  {
    let rich =
      #"{"state":"open","merged":false,"draft":false,"mergeable":true,"mergeable_state":"clean","changed_files":1,"head":{"ref":"draft/article","sha":"head","repo":{"full_name":"owner/site"}},"base":{"ref":"main","sha":"base","repo":{"full_name":"owner/site"}}}"#
    return [
      pullStatus(), response(rich), response("[\(changeJSON())]"), content(), response(checks),
      response(#"{"total_count":0,"state":"pending"}"#), ref("head"), ref("base"),
    ]
  }
  private func assertFailure(
    _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected safe rejection", file: file, line: line)
    } catch {}
  }
}
