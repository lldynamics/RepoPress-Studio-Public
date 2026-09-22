import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishExecutionVerificationTests:
  RemoteRepositoryPublishServiceTestCase
{
  private func plan(
    provider: RepositoryProvider = .github, content: String = "# Frozen", expected: String? = nil
  ) -> (PublishExecutionPlan, SiteProfile) {
    let profile = provider == .github ? githubProfileForDeletion() : gitLabProfileForDeletion()
    let file = PublishPackageFile(
      kind: .markdown, repositoryPath: "content/frozen.md", content: content,
      expectedRemoteSHA: expected)
    let package = PublishPackage(
      draftID: UUID(), title: "Frozen", markdownPath: file.repositoryPath, files: [file],
      commitMessage: "Frozen", reviewBranchName: "publish/frozen", reviewTitle: "Frozen",
      reviewChecklist: [])
    let preview = RemoteRepositoryPublishPreview(
      provider: provider, repositoryName: profile.repositoryDisplayName, mode: .directCommit,
      branchName: "main", targetBranch: "main", changedPaths: [file.repositoryPath], hasToken: true,
      accessCheck: RemoteRepositoryAccessCheck(
        provider: provider, repositoryName: profile.repositoryDisplayName, defaultBranch: "main",
        canRead: true, canWrite: true, message: "ok"), blockingIssues: [], warningIssues: [])
    let service = RemoteRepositoryPublishService()
    let data = Data(content.utf8)
    let blob = service.gitBlobSHA(for: data)
    return (
      PublishExecutionPlan(
        package: package, batchItems: [],
        target: RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview),
        branchName: "main",
        contentSHA256ByPath: [file.repositoryPath: WorkbenchRecordPayload.digest(data)],
        gitBlobSHAByPath: [file.repositoryPath: blob]), profile
    )
  }

  func testGitHubAcceptedUsesOnlyGETAndExactRemoteBlobAtFrozenHead() async throws {
    let (plan, profile) = plan()
    let blob = try XCTUnwrap(plan.gitBlobSHAByPath["content/frozen.md"])
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"head"}}"#), response(json: #"{"sha":"\#(blob)"}"#),
      response(json: #"{"object":{"sha":"head"}}"#),
    ])
    let result = try await RemoteRepositoryPublishService(transport: transport).verifyExecution(
      plan, profile: profile, token: "token")
    guard case .accepted(let accepted) = result else { return XCTFail("expected accepted") }
    XCTAssertEqual(accepted.commitSHA, "head")
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testRemoteEqualToOriginalVersionIsUnchanged() async throws {
    let (plan, profile) = plan(expected: "old")
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"head"}}"#), response(json: #"{"sha":"old"}"#),
      response(json: #"{"object":{"sha":"head"}}"#),
    ])
    guard
      case .unchanged = try await RemoteRepositoryPublishService(transport: transport)
        .verifyExecution(plan, profile: profile, token: "token")
    else { return XCTFail("expected unchanged") }
  }

  func testMixedVersionIsUnresolved() async throws {
    let (plan, profile) = plan(expected: "old")
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"head"}}"#), response(json: #"{"sha":"other"}"#),
      response(json: #"{"object":{"sha":"head"}}"#),
    ])
    guard
      case .unresolved = try await RemoteRepositoryPublishService(transport: transport)
        .verifyExecution(plan, profile: profile, token: "token")
    else { return XCTFail("expected unresolved") }
  }

  func testBranchHeadChangeDuringVerificationCannotSucceed() async throws {
    let (plan, profile) = plan()
    let blob = try XCTUnwrap(plan.gitBlobSHAByPath["content/frozen.md"])
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"head-1"}}"#), response(json: #"{"sha":"\#(blob)"}"#),
      response(json: #"{"object":{"sha":"head-2"}}"#),
    ])
    guard
      case .unresolved = try await RemoteRepositoryPublishService(transport: transport)
        .verifyExecution(plan, profile: profile, token: "token")
    else { return XCTFail("expected unresolved") }
  }

  func testPlanWithoutHashesFailsBeforeAnyHTTPRequest() async throws {
    let (valid, profile) = plan()
    let invalid = PublishExecutionPlan(
      package: valid.package, batchItems: [], target: valid.target, branchName: valid.branchName,
      contentSHA256ByPath: [:], gitBlobSHAByPath: [:])
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).verifyExecution(
        invalid, profile: profile, token: "token")
      XCTFail("expected validation error")
    } catch {
      let requests = await transport.capturedRequests()
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testGitLabExistingFileWithoutCommitEvidenceIsUnresolvedAndUsesOnlyGET() async throws {
    let (plan, profile) = plan(provider: .gitlab)
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"commit":{"id":"head"}}"#),
      response(json: #"{"last_commit_id":null,"content":"different","encoding":"text"}"#),
      response(json: #"{"commit":{"id":"head"}}"#),
    ])
    let result = try await RemoteRepositoryPublishService(transport: transport).verifyExecution(
      plan, profile: profile, token: "token")
    guard case .unresolved = result else { return XCTFail("expected unresolved") }
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET"])
  }

  func testGitHubPutFailureDoesNotDeleteNewReviewBranch() async throws {
    let (plan, profile) = plan()
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"object":{"sha":"base"}}"#),
      response(
        statusCode: 201, json: #"{"ref":"refs/heads/publish/frozen","object":{"sha":"base"}}"#),
      response(statusCode: 404, json: #"{"message":"Not Found"}"#),
      response(statusCode: 500, json: #"{"message":"response lost"}"#),
    ])
    do {
      _ = try await RemoteRepositoryPublishService(transport: transport).publish(
        package: plan.package, profile: profile, mode: .reviewRequest, token: "token")
      XCTFail("expected publish failure")
    } catch {
      let requests = await transport.capturedRequests()
      XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "PUT"])
      XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })
    }
  }
}
