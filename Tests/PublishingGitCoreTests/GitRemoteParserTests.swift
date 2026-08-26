import Foundation
import XCTest

@testable import PublishingGitCore

final class GitRemoteParserTests: XCTestCase {
  func testRedactsHTTPSCredentialsQueryAndFragment() throws {
    let remote = try XCTUnwrap(
      GitRemoteParser.parseRepositoryRemote(
        "https://oauth-user:super-secret@github.com/owner/site.git?access_token=query-secret#fragment"
      )
    )

    XCTAssertEqual(remote.provider, .github)
    XCTAssertEqual(remote.owner, "owner")
    XCTAssertEqual(remote.name, "site")
    XCTAssertEqual(remote.repositoryBaseURL, "https://api.github.com")
    XCTAssertEqual(remote.remoteURL, "https://github.com/owner/site.git")
    XCTAssertFalse(remote.remoteURL.contains("oauth-user"))
    XCTAssertFalse(remote.remoteURL.contains("super-secret"))
    XCTAssertFalse(remote.remoteURL.contains("query-secret"))
    XCTAssertFalse(remote.remoteURL.contains("fragment"))
  }

  func testRedactsSCPCredentialPrefix() throws {
    let remote = try XCTUnwrap(
      GitRemoteParser.parseRepositoryRemote(
        "oauth2:super-secret@gitlab.com:group/site.git"
      )
    )

    XCTAssertEqual(remote.provider, .gitlab)
    XCTAssertEqual(remote.owner, "group")
    XCTAssertEqual(remote.name, "site")
    XCTAssertEqual(remote.repositoryBaseURL, "https://gitlab.com")
    XCTAssertEqual(remote.remoteURL, "gitlab.com:group/site.git")
    XCTAssertFalse(remote.remoteURL.contains("oauth2"))
    XCTAssertFalse(remote.remoteURL.contains("super-secret"))
  }

  func testSupportsNestedGroupsAndCustomHosts() throws {
    let nestedGitLab = try XCTUnwrap(
      GitRemoteParser.parseRepositoryRemote(
        "https://gitlab.internal.example/group/subgroup/site.git"
      )
    )
    XCTAssertEqual(nestedGitLab.provider, .gitlab)
    XCTAssertEqual(nestedGitLab.owner, "group/subgroup")
    XCTAssertEqual(nestedGitLab.name, "site")
    XCTAssertEqual(nestedGitLab.repositoryBaseURL, "https://gitlab.internal.example")

    let customGitHub = try XCTUnwrap(
      GitRemoteParser.parseRepositoryRemote(
        "git@github.enterprise.example:team/site.git"
      )
    )
    XCTAssertEqual(customGitHub.provider, .github)
    XCTAssertEqual(customGitHub.owner, "team")
    XCTAssertEqual(customGitHub.name, "site")
    XCTAssertEqual(customGitHub.repositoryBaseURL, "https://github.enterprise.example")
  }

  func testUsesGitHubDefaultAPIBaseForGitHubCom() throws {
    let remote = try XCTUnwrap(
      GitRemoteParser.parseRepositoryRemote("git@github.com:owner/repo.git")
    )

    XCTAssertEqual(remote.repositoryBaseURL, "https://api.github.com")
    XCTAssertEqual(remote.remoteURL, "github.com:owner/repo.git")
  }

  func testRejectsInvalidUnknownAndIncompleteRemotes() {
    let invalidRemotes = [
      "",
      "https://github.com",
      "https://github.com/owner",
      "https://github.com/owner/",
      "https://unknown.example/owner/repo.git",
      "github.com:owner",
      "git@github.com:",
      "git@github.com:owner/repo?token=secret",
      "https://github.com/owner/../repo.git"
    ]

    for remote in invalidRemotes {
      XCTAssertNil(
        GitRemoteParser.parseRepositoryRemote(remote),
        "Expected invalid remote to be rejected: \(remote)"
      )
    }
  }

  func testPreservesLegacyURLSchemeAcceptanceWhileRedactingCredentials() throws {
    for scheme in ["http", "ssh"] {
      let remote = try XCTUnwrap(
        GitRemoteParser.parseRepositoryRemote(
          "\(scheme)://git:secret@github.com/owner/repo.git?token=hidden#fragment"
        )
      )
      XCTAssertEqual(remote.remoteURL, "\(scheme)://github.com/owner/repo.git")
      XCTAssertEqual(remote.repositoryBaseURL, "https://api.github.com")
      XCTAssertFalse(remote.remoteURL.contains("secret"))
      XCTAssertFalse(remote.remoteURL.contains("hidden"))
    }
  }

  func testValidatesUpstreamNameBeforeExtractingRemote() {
    XCTAssertEqual(
      GitRemoteParser.remoteName(fromUpstreamName: " origin/main "),
      "origin"
    )

    for upstream in [
      "origin",
      "/main",
      "origin\\main",
      "origin/../main",
      "https://github.com/owner/repo",
      "orig!n/main"
    ] {
      XCTAssertNil(
        GitRemoteParser.remoteName(fromUpstreamName: upstream),
        "Expected invalid upstream to be rejected: \(upstream)"
      )
    }
  }
}
