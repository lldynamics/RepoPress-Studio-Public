import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceAccessAndCreationTests:
  RemoteRepositoryPublishServiceTestCase
{
  func testAccessCheckReportsWritableGitHubRepository() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true,"maintain":false,"admin":false}}"#,
        headers: [
          "X-OAuth-Scopes": "repo, workflow",
          "X-Accepted-OAuth-Scopes": "repo",
        ]
      )
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"

    let check = try await service.checkAccess(profile: profile, token: "token")

    XCTAssertEqual(check.provider, .github)
    XCTAssertEqual(check.repositoryName, "owner/site")
    XCTAssertEqual(check.apiBaseURL, "https://api.github.com")
    XCTAssertEqual(check.defaultBranch, "main")
    XCTAssertEqual(check.targetBranch, "main")
    XCTAssertEqual(check.publishStrategy, .reviewRequest)
    XCTAssertTrue(check.canRead)
    XCTAssertTrue(check.canWrite)
    XCTAssertEqual(
      check.permissionSummary,
      CoreL10n.format(
        "GitHub repository permissions: push=%@, maintain=%@, admin=%@; active=%@.",
        "true",
        "false",
        "false",
        "push"
      )
    )
    XCTAssertEqual(
      check.tokenScopeSummary,
      CoreL10n.format("GitHub OAuth scopes: %@; accepted: %@.", "repo, workflow", "repo")
    )
    XCTAssertTrue(check.minimumWritePermission.contains("Contents: Read and write"))
    XCTAssertTrue(check.minimumWritePermission.contains("Pull requests: Read and write"))
    XCTAssertTrue(check.message.contains("PR 创建权限需在实际创建时验证"))
  }

  func testAccessCheckReportsNormalizedGitLabAPIBaseURL() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(
        json:
          #"{"path_with_namespace":"group/site","default_branch":"main","permissions":{"project_access":{"access_level":30}}}"#
      )
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"

    let check = try await service.checkAccess(profile: profile, token: "token")

    XCTAssertEqual(check.provider, .gitlab)
    XCTAssertEqual(check.repositoryName, "group/site")
    XCTAssertEqual(check.apiBaseURL, "https://gitlab.com/api/v4")
    XCTAssertEqual(check.defaultBranch, "main")
    XCTAssertEqual(check.targetBranch, "main")
    XCTAssertEqual(check.publishStrategy, .reviewRequest)
    XCTAssertTrue(check.canRead)
    XCTAssertTrue(check.canWrite)
    XCTAssertEqual(
      check.permissionSummary,
      CoreL10n.format(
        "GitLab access level: project=%@ (%@), group=%@ (%@), effective=%@ (%@).",
        "30",
        "Developer",
        "0",
        "No access",
        "30",
        "Developer"
      )
    )
    XCTAssertNil(check.tokenScopeSummary)
    XCTAssertTrue(check.minimumWritePermission.contains("Developer(30)"))
  }

  func testAccessCheckRejectsHTTPBaseURLBeforeSendingGitHubToken() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "http://api.github.example"
    profile.repoOwner = "owner"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: "secret-token")
      XCTFail("Expected an insecure base URL error")
    } catch {
      XCTAssertEqual(
        error as? RemoteRepositoryPublishError,
        .insecureBaseURL
      )
      XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckRejectsHTTPBaseURLBeforeSendingGitLabToken() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "http://gitlab.example"
    profile.repoOwner = "group"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: "secret-token")
      XCTFail("Expected an insecure base URL error")
    } catch {
      XCTAssertEqual(
        error as? RemoteRepositoryPublishError,
        .insecureBaseURL
      )
      XCTAssertTrue(error.localizedDescription.contains("发送 Token"))
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckRejectsCredentialedQueryAndFragmentBaseURLs() async {
    let transport = SequencedRemoteRepositoryTransport(responses: [])
    let service = RemoteRepositoryPublishService(transport: transport)
    let insecureURLs = [
      "https://user:password@api.example.com",
      "https://api.example.com?redirect=https://other.example",
      "https://api.example.com#fragment",
    ]

    for baseURL in insecureURLs {
      var profile = SiteProfile.defaultProfile
      profile.repositoryBaseURL = baseURL
      profile.repoOwner = "owner"
      profile.repoName = "site"
      do {
        _ = try await service.checkAccess(profile: profile, token: "secret-token")
        XCTFail("Expected insecure base URL rejection")
      } catch {
        XCTAssertEqual(error as? RemoteRepositoryPublishError, .insecureBaseURL)
        XCTAssertFalse(error.localizedDescription.contains("password"))
      }
    }

    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testAccessCheckDecodesLegacyPayloadWithoutPermissionDiagnostics() throws {
    let data = """
      {
        "provider": "github",
        "repositoryName": "owner/site",
        "apiBaseURL": "https://api.github.com",
        "defaultBranch": "main",
        "canRead": true,
        "canWrite": false,
        "message": "GitHub Token 可读取仓库，但未确认写入权限。"
      }
      """.data(using: .utf8)!

    let check = try JSONDecoder().decode(RemoteRepositoryAccessCheck.self, from: data)

    XCTAssertEqual(check.repositoryName, "owner/site")
    XCTAssertFalse(check.canWrite)
    XCTAssertEqual(check.permissionSummary, CoreL10n.text("未确认写入权限。"))
    XCTAssertEqual(check.minimumWritePermission, CoreL10n.text("需要仓库写入权限。"))
    XCTAssertNil(check.tokenScopeSummary)
    XCTAssertNil(check.checkedAt)
    XCTAssertFalse(check.isFresh())
  }

  func testRemoteAPIHTTPErrorDescriptionsIncludeActionableTokenAndPermissionGuidance() async throws
  {
    let githubTransport = SequencedRemoteRepositoryTransport(responses: [
      response(
        statusCode: 403,
        json:
          #"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest"}"#
      )
    ])
    let githubService = RemoteRepositoryPublishService(transport: githubTransport)
    var githubProfile = SiteProfile.defaultProfile
    githubProfile.repositoryProvider = .github
    githubProfile.repoOwner = "owner"
    githubProfile.repoName = "site"

    do {
      _ = try await githubService.checkAccess(profile: githubProfile, token: "github-token")
      XCTFail("Expected GitHub permission failure")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("HTTP 403"))
      XCTAssertTrue(message.contains("Contents: Read and write"))
      XCTAssertTrue(message.contains("Resource not accessible by personal access token"))
      XCTAssertTrue(message.contains("https://docs.github.com/rest"))
    }

    let gitLabTransport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 401, json: #"{"message":"401 Unauthorized"}"#)
    ])
    let gitLabService = RemoteRepositoryPublishService(transport: gitLabTransport)
    var gitLabProfile = SiteProfile.defaultProfile
    gitLabProfile.repositoryProvider = .gitlab
    gitLabProfile.repositoryBaseURL = "https://gitlab.com"
    gitLabProfile.repoOwner = "group"
    gitLabProfile.repoName = "site"

    do {
      _ = try await gitLabService.checkAccess(profile: gitLabProfile, token: "gitlab-token")
      XCTFail("Expected GitLab token failure")
    } catch {
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("HTTP 401"))
      XCTAssertTrue(message.contains("GitHub/GitLab"))
      XCTAssertTrue(message.contains("401 Unauthorized"))
    }
  }

  func testRemoteAPIHTTPErrorBodyIsBoundedAndRedactsRequestToken() async {
    let token = "github-super-secret-token-123456789"
    let body =
      #"{"message":"Bearer \#(token)","token":"\#(token)","detail":""#
      + String(repeating: "x", count: 4_000)
      + #""}"#
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(statusCode: 500, json: body)
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repoOwner = "owner"
    profile.repoName = "site"

    do {
      _ = try await service.checkAccess(profile: profile, token: token)
      XCTFail("Expected sanitized remote API failure")
    } catch let error as RemoteRepositoryPublishError {
      guard case .httpStatus(500, let sanitizedBody) = error else {
        XCTFail("Expected HTTP failure, got \(error)")
        return
      }
      XCTAssertFalse(sanitizedBody.contains(token))
      XCTAssertTrue(sanitizedBody.contains("[REDACTED]"))
      XCTAssertTrue(sanitizedBody.contains("远端响应已截断"))
      XCTAssertLessThan(sanitizedBody.count, 2_100)
    } catch {
      XCTFail("Expected RemoteRepositoryPublishError, got \(error)")
    }
  }

  func testCreatesGitHubUserRepositoryWhenOwnerMatchesTokenUser() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"login":"owner"}"#),
      response(
        json:
          #"{"full_name":"owner/site","default_branch":"main","ssh_url":"git@github.com:owner/site.git","clone_url":"https://github.com/owner/site.git","html_url":"https://github.com/owner/site","private":false}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.name = "Personal Site"

    let result = try await service.createRepository(
      profile: profile,
      token: "github-token",
      privateRepository: false
    )

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.repositoryName, "owner/site")
    XCTAssertEqual(result.defaultBranch, "main")
    XCTAssertEqual(result.sshURL, "git@github.com:owner/site.git")
    XCTAssertEqual(result.htmlURL, "https://github.com/owner/site")
    XCTAssertFalse(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/user/repos")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")

    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["description"] as? String, "Personal Site")
    XCTAssertEqual(body["private"] as? Bool, false)
    XCTAssertEqual(body["auto_init"] as? Bool, false)
  }

  func testCreatesGitHubOrganizationRepositoryAsPrivateByDefault() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"login":"me"}"#),
      response(
        json:
          #"{"full_name":"org/site","ssh_url":"git@github.com:org/site.git","clone_url":"https://github.com/org/site.git","html_url":"https://github.com/org/site","private":true}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "org"
    profile.repoName = "site"

    let result = try await service.createRepository(
      profile: profile,
      token: "github-token"
    )

    XCTAssertEqual(result.repositoryName, "org/site")
    XCTAssertEqual(result.sshURL, "git@github.com:org/site.git")
    XCTAssertTrue(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/orgs/org/repos")
    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["private"] as? Bool, true)
  }

  func testCreatesGitLabGroupProject() async throws {
    let transport = SequencedRemoteRepositoryTransport(responses: [
      response(json: #"{"id":42,"full_path":"group/subgroup"}"#),
      response(
        json:
          #"{"path_with_namespace":"group/subgroup/site","default_branch":"main","ssh_url_to_repo":"git@gitlab.com:group/subgroup/site.git","http_url_to_repo":"https://gitlab.com/group/subgroup/site.git","web_url":"https://gitlab.com/group/subgroup/site","visibility":"private"}"#
      ),
    ])
    let service = RemoteRepositoryPublishService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group/subgroup"
    profile.repoName = "site"
    profile.name = "Personal Site"

    let result = try await service.createRepository(
      profile: profile,
      token: "gitlab-token",
      privateRepository: true
    )

    XCTAssertEqual(result.provider, .gitlab)
    XCTAssertEqual(result.repositoryName, "group/subgroup/site")
    XCTAssertEqual(result.defaultBranch, "main")
    XCTAssertEqual(result.sshURL, "git@gitlab.com:group/subgroup/site.git")
    XCTAssertEqual(result.cloneURL, "https://gitlab.com/group/subgroup/site.git")
    XCTAssertEqual(result.htmlURL, "https://gitlab.com/group/subgroup/site")
    XCTAssertTrue(result.privateRepository)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(percentEncodedPath(requests[0].url), "/api/v4/groups/group%2Fsubgroup")
    XCTAssertEqual(percentEncodedPath(requests[1].url), "/api/v4/projects")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")

    let body = try jsonBody(requests[1])
    XCTAssertEqual(body["name"] as? String, "site")
    XCTAssertEqual(body["path"] as? String, "site")
    XCTAssertEqual(body["description"] as? String, "Personal Site")
    XCTAssertEqual(body["visibility"] as? String, "private")
    XCTAssertEqual(body["namespace_id"] as? Int, 42)
    XCTAssertEqual(body["initialize_with_readme"] as? Bool, false)
  }

  func testCreateRepositoryRequiresRepositoryName() async throws {
    let service = RemoteRepositoryPublishService(
      transport: SequencedRemoteRepositoryTransport(responses: [])
    )
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = " "

    do {
      _ = try await service.createRepository(profile: profile, token: "github-token")
      XCTFail("Expected missing repository name error")
    } catch let error as RemoteRepositoryPublishError {
      XCTAssertEqual(error, .missingRepositoryName)
    }
  }

}
