import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RemoteRepositoryRollbackSafetyTests: WorkbenchStoreRemotePublishingTestCase {
  func testServiceRejectsForkProviderEndpointAndBranchChangesBeforeAnyRequest() async throws {
    let original = configuredProfile()
    let draft = try RemoteRepositoryRollbackDraft.make(record: releaseRecord(profile: original))
    let changes: [(inout SiteProfile) -> Void] = [
      { $0.repoOwner = "fork-owner" },
      { $0.repoName = "fork-site" },
      { $0.repositoryProvider = .gitlab },
      { $0.repositoryBaseURL = "https://github.example.com/api/v3" },
      { $0.branch = "preview" },
    ]
    for change in changes {
      var current = original
      change(&current)
      let transport = CountingRemoteRepositoryTransport()
      let service = RemoteRepositoryPublishService(transport: transport)
      do {
        _ = try await service.rollback(draft: draft, profile: current, token: "token")
        XCTFail("A matching commit SHA in another repository must not authorize rollback")
      } catch {
        XCTAssertEqual(error as? RemoteRepositoryRollbackSafetyError, .repositoryIdentityChanged)
      }
      let requestCount = await transport.requestCount()
      XCTAssertEqual(requestCount, 0)
    }
  }

  func testLegacyRollbackPayloadWithoutIdentityDecodesButCannotWrite() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let service = RemoteRepositoryPublishService(transport: transport)
    let draft = RemoteRepositoryRollbackDraft(
      recordID: UUID(), title: "Rollback", commitMessage: "Rollback", targetBranch: "main",
      commitSHA: "same-sha-in-a-fork", changedPaths: ["content/posts/article.md"])
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
    json.removeValue(forKey: "repositoryIdentity")
    let legacy = try JSONDecoder().decode(
      RemoteRepositoryRollbackDraft.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.repositoryIdentity)
    do {
      _ = try await service.rollback(draft: legacy, profile: configuredProfile(), token: "token")
      XCTFail("Legacy SHA-only drafts must fail closed")
    } catch {
      XCTAssertEqual(error as? RemoteRepositoryRollbackSafetyError, .missingRecordedIdentity)
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testReleaseRecordRequiresEveryRepositoryCoordinateAndAnExplicitBranch() {
    let original = releaseRecord(profile: configuredProfile())
    let incompleteRecords: [ReleaseRecord] = [
      changing(original) { $0.repositoryProvider = nil },
      changing(original) { $0.repositoryBaseURL = nil },
      changing(original) { $0.repoOwner = " " },
      changing(original) { $0.repoName = nil },
      changing(original) {
        $0.targetBranch = nil
        $0.branchName = nil
      },
    ]
    for record in incompleteRecords {
      XCTAssertThrowsError(try RemoteRepositoryRollbackDraft.make(record: record)) { error in
        XCTAssertEqual(error as? RemoteRepositoryRollbackSafetyError, .missingRecordedIdentity)
      }
    }
  }

  func testLegacyRecordWithCompleteCoordinatesUsesCanonicalGitLabAPIIdentity() throws {
    var profile = configuredProfile()
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.example.com"
    let record = releaseRecord(profile: profile)
    let draft = try RemoteRepositoryRollbackDraft.make(record: record)
    XCTAssertEqual(draft.repositoryIdentity?.baseURL, "https://gitlab.example.com/api/v4")
    profile.repositoryBaseURL = "https://gitlab.example.com/api/v4/"
    XCTAssertNoThrow(try draft.validateRepositoryIdentity(profile: profile))
  }

  func testStoreRejectsChangedProfileAndMissingProfileWithoutActiveSiteFallback() async throws {
    for missingProfile in [false, true] {
      let transport = CountingRemoteRepositoryTransport()
      let tokenStore = repositoryTokenStoreForTest()
      let store = WorkbenchStore(
        persistence: try TestWorkbenchFactory.persistence(),
        remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
        repositoryTokenStore: tokenStore)
      var originalProfile = configuredProfile()
      originalProfile.id = store.activeProfile.id
      store.updateActiveProfile(originalProfile)
      let record = releaseRecord(profile: originalProfile)
      store.setReleaseRecords([record])
      if missingProfile {
        var replacement = originalProfile
        replacement.id = UUID()
        store.setProfiles([replacement])
        store.selectProfile(replacement.id)
      } else {
        var fork = originalProfile
        fork.repoOwner = "fork-owner"
        store.updateActiveProfile(fork)
      }
      let current = store.activeProfile
      try tokenStore.saveRepositoryToken("token", for: current)
      store.refreshRepositoryTokenAvailability()

      let result = await store.rollbackRemoteRelease(record)

      XCTAssertNil(result)
      XCTAssertNil(store.remoteRepositoryRollbackResult)
      XCTAssertEqual(store.releaseRecords.map(\.id), [record.id])
      let expectedError: RemoteRepositoryRollbackSafetyError =
        missingProfile
        ? .missingRecordedProfile : .repositoryIdentityChanged
      XCTAssertTrue(
        try XCTUnwrap(store.publishActionMessage).contains(expectedError.localizedDescription))
      let requestCount = await transport.requestCount()
      XCTAssertEqual(requestCount, 0)
    }
  }

  private func configuredProfile() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  private func releaseRecord(profile: SiteProfile) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteDirectCommit, title: "Published", summary: "Published",
      siteProfileID: profile.id,
      changedPaths: ["content/posts/article.md"], repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL, repoOwner: profile.repoOwner,
      repoName: profile.repoName, branchName: profile.branch, targetBranch: profile.branch,
      commitSHA: "same-sha-in-a-fork")
  }

  private func changing(_ record: ReleaseRecord, update: (inout ReleaseRecord) -> Void)
    -> ReleaseRecord
  {
    var changed = record
    update(&changed)
    return changed
  }
}
