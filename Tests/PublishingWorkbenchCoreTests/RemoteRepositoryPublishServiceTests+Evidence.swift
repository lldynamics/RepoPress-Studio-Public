import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryPublishServiceEvidenceTests: RemoteRepositoryPublishServiceTestCase {
  func testRemoteRepositoryAccessCheckBuildsGitHubEvidencePackageWithoutTokenLeak() {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: "https://api.github.com",
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      permissionSummary: "permissions.push=true",
      tokenScopeSummary: "repo, workflow",
      minimumWritePermission: "GitHub permissions.push=true 或 admin=true",
      message: "GitHub Token 可读取并写入 owner/site。"
    )

    let markdown = check.accessEvidenceMarkdown

    XCTAssertEqual(
      check.accessVerificationCommands,
      [
        "curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" 'https://api.github.com/repos/owner/site'"
      ]
    )
    XCTAssertTrue(markdown.contains(CoreL10n.format("# %@ Token 权限证据包", "GitHub")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 仓库：%@", "owner/site")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 可写入：%@", CoreL10n.text("是"))))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- Token scope：%@", "repo, workflow")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- [%@] Token 满足内容写入所需权限", "x")))
    XCTAssertTrue(markdown.contains(CoreL10n.text("- [ ] PR 创建权限需在实际创建时验证")))
    XCTAssertTrue(markdown.contains("curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\""))
    XCTAssertFalse(markdown.contains("secret-token"))
  }

  func testRemoteRepositoryAccessCheckBuildsGitLabEvidencePackageAndEncodesProjectPath() {
    let check = RemoteRepositoryAccessCheck(
      provider: .gitlab,
      repositoryName: "group/sub/site",
      apiBaseURL: "https://gitlab.example.com/api/v4",
      defaultBranch: "main",
      canRead: true,
      canWrite: false,
      permissionSummary: "access_level=20",
      tokenScopeSummary: "read_api",
      minimumWritePermission: "GitLab Developer 及以上或 api scope",
      message: "GitLab Token 可读但未确认写入。"
    )

    let markdown = check.accessEvidenceMarkdown

    XCTAssertEqual(
      check.accessVerificationCommands,
      [
        "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsub%2Fsite'"
      ]
    )
    XCTAssertTrue(markdown.contains(CoreL10n.format("# %@ Token 权限证据包", "GitLab")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 可写入：%@", CoreL10n.text("否"))))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- [%@] Token 满足内容写入所需权限", " ")))
    XCTAssertTrue(markdown.contains("GitLab Token 可读但未确认写入。"))
    XCTAssertFalse(markdown.contains("PRIVATE-TOKEN: secret"))
  }

  func testRemotePublishResultPresentationBuildsStableClipboardSummary() {
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "https://gitlab.example.com/api/v4",
      mode: .reviewRequest,
      branchName: "publish/post",
      targetBranch: "main",
      changedPaths: ["content/posts/post.md", "static/images/post.png"],
      commitSHA: "1234567890abcdef",
      reviewURL: "https://gitlab.com/group/site/-/merge_requests/5",
      reviewTitle: "Publish: Post"
    )

    XCTAssertEqual(result.shortCommitSHA, "12345678")
    XCTAssertEqual(result.displayTitle, "GitLab \(CoreL10n.text("线上 PR/MR"))")
    XCTAssertEqual(result.branchSummary, "publish/post -> main")
    XCTAssertTrue(result.clipboardSummary.contains(CoreL10n.format("仓库：%@", "group/site")))
    XCTAssertTrue(
      result.clipboardSummary.contains(CoreL10n.format("Commit：%@", "1234567890abcdef")))
    XCTAssertTrue(
      result.clipboardSummary.contains(
        CoreL10n.format("PR/MR：%@", "https://gitlab.com/group/site/-/merge_requests/5")))
    XCTAssertTrue(result.clipboardSummary.contains("- content/posts/post.md"))
    XCTAssertTrue(result.clipboardSummary.contains("- static/images/post.png"))

    let verification = result.remoteVerificationMarkdown
    XCTAssertTrue(verification.contains(CoreL10n.format("# %@ 线上发布实测包", "GitLab")))
    XCTAssertTrue(
      verification.contains(
        "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsite/repository/commits/1234567890abcdef'"
      ))
    XCTAssertTrue(
      verification.contains(
        "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" 'https://gitlab.example.com/api/v4/projects/group%2Fsite/merge_requests/5'"
      ))
    XCTAssertTrue(
      verification.contains("repository/files/content%2Fposts%2Fpost.md?ref=publish%2Fpost"))
    XCTAssertTrue(verification.contains(CoreL10n.text("- [ ] 部署状态面板已刷新到最新记录。")))
  }

  func testRemotePublishResultDecodesLegacyPayloadWithoutRepositoryContext() throws {
    let data = """
      {
        "provider": "github",
        "mode": "directCommit",
        "branchName": "main",
        "targetBranch": "main",
        "changedPaths": ["content/posts/post.md"],
        "commitSHA": "abc123"
      }
      """.data(using: .utf8)!

    let result = try JSONDecoder().decode(RemoteRepositoryPublishResult.self, from: data)

    XCTAssertNil(result.repositoryName)
    XCTAssertNil(result.apiBaseURL)
    XCTAssertTrue(result.remoteVerificationCommands.isEmpty)
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        CoreL10n.text("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testAccessEvidenceRefusesCredentialCommandForInsecureDecodedBaseURL() {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: "http://api.example.com",
      defaultBranch: nil,
      canRead: true,
      canWrite: true,
      permissionSummary: "write=true",
      minimumWritePermission: "write",
      message: "checked"
    )

    XCTAssertTrue(check.accessVerificationCommands.isEmpty)
    XCTAssertTrue(
      check.accessEvidenceMarkdown.contains(
        CoreL10n.text("当前权限检查缺少仓库名，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testRemoteVerificationRefusesCredentialCommandForInsecureDecodedBaseURL() {
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "http://gitlab.example/api/v4",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/post.md"],
      commitSHA: "abc123"
    )

    XCTAssertTrue(result.remoteVerificationCommands.isEmpty)
    XCTAssertTrue(
      result.remoteVerificationMarkdown.contains(
        CoreL10n.text("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
      )
    )
  }

  func testAccessEvidenceShellQuotesUserControlledURLComponents() throws {
    let check = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/$(touch injected)'repo`id`",
      apiBaseURL: "https://api.example.com",
      defaultBranch: nil,
      canRead: true,
      canWrite: true,
      permissionSummary: "write=true",
      minimumWritePermission: "write",
      message: "checked"
    )

    let command = try XCTUnwrap(check.accessVerificationCommands.first)
    XCTAssertTrue(command.contains("'https://api.example.com/repos/"))
    XCTAssertTrue(command.contains("'\"'\"'"))
    XCTAssertFalse(command.contains("\"https://api.example.com"))
  }

}
