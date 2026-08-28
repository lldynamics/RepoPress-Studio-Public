import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class CoreLocalizationTests: XCTestCase {
  func testCoreLocalizationResolvesChineseAndEnglishResources() {
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "zh-Hans")),
      "标题为空"
    )
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "en")),
      "Missing title"
    )
  }

  func testCoreLocalizationPreservesFormatArguments() {
    XCTAssertEqual(
      CoreL10n.format(
        "%@ 已被另一篇草稿占用。",
        locale: Locale(identifier: "en"),
        arguments: ["content/post.md"]
      ),
      "content/post.md is already used by another draft."
    )
  }

  func testEmbeddedHTMLDiagnosticsResolveInEnglish() {
    let english = Locale(identifier: "en")

    XCTAssertEqual(
      CoreL10n.text("HTML 链接已拦截", locale: english),
      "Unsafe HTML URL blocked"
    )
    XCTAssertEqual(
      CoreL10n.text("HTML 片段格式无效", locale: english),
      "Invalid HTML fragment"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "<%@> 的 %@ 属性不在安全白名单中。",
        locale: english,
        arguments: ["img", "onerror"]
      ),
      "<img> uses the onerror attribute, which is not in the safe allowlist."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "<%@> 需要单独成块，开始标签前和结束标签后只能有空白。",
        locale: english,
        arguments: ["details"]
      ),
      "<details> must be a standalone block with only whitespace before its opening tag and after its closing tag."
    )
  }

  func testDeploymentDiagnosticsResolveEnglishCopyAndFormatting() {
    XCTAssertEqual(
      CoreL10n.text("发布页面社交元数据", locale: Locale(identifier: "en")),
      "Published page social metadata"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "最近一次 %@ 部署不是当前发布：%@。请等待目标 commit 部署完成或检查部署队列。",
        locale: Locale(identifier: "en"),
        arguments: ["Netlify", "expected branch main, actual preview"]
      ),
      "The latest Netlify deployment does not match the current release: expected branch main, actual preview. Wait for the target commit to deploy or check the deployment queue."
    )
    XCTAssertEqual(
      CoreL10n.text("# 部署轮询后续处理", locale: Locale(identifier: "en")),
      "# Deployment Polling Follow-up"
    )
    XCTAssertEqual(
      CoreL10n.text("# 发布后校验报告", locale: Locale(identifier: "en")),
      "# Post-publish Validation Report"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "部署轮询已检查 %@ 条待部署记录：%@。",
        locale: Locale(identifier: "en"),
        arguments: ["3", "Healthy 1, Deploying 2"]
      ),
      "Deployment polling checked 3 pending records: Healthy 1, Deploying 2."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "- [%@] %@：%@",
        locale: Locale(identifier: "en"),
        arguments: ["x", "Published page content", "Article title found"]
      ),
      "- [x] Published page content: Article title found"
    )
  }

  func testReleaseLedgerAndRecoveryCopyResolveInEnglish() {
    XCTAssertEqual(
      CoreL10n.text("# 发布台账", locale: Locale(identifier: "en")),
      "# Release Ledger"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "%@ 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。",
        locale: Locale(identifier: "en"),
        arguments: ["2"]
      ),
      "2 remote publishes stopped after partial completion. Confirm the commit, review, or rollback plan."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "基于 %@ 创建 %@，生成 revert 提交来撤销 %@，再用下方回滚草稿发起 PR/MR。",
        locale: Locale(identifier: "en"),
        arguments: ["main", "rollback/abcdef12", "abcdef12"]
      ),
      "Use main as the base to create rollback/abcdef12, generate a revert commit for abcdef12, then use the rollback draft below to open a PR/MR."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "关闭发布 Review：%@",
        locale: Locale(identifier: "en"),
        arguments: ["Article"]
      ),
      "Close publishing review: Article"
    )
  }

  func testPublishingExecutionFeedbackResolvesInEnglish() {
    let english = Locale(identifier: "en")

    XCTAssertEqual(
      CoreL10n.text("线上直接提交", locale: english),
      "Online Direct Commit"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "正在通过 %@ 执行 %@…",
        locale: english,
        arguments: ["GitHub", "Online Direct Commit"]
      ),
      "Using GitHub to run Online Direct Commit…"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "线上回滚完成：%@",
        locale: english,
        arguments: ["rollback"]
      ),
      "Online rollback completed: rollback"
    )
    XCTAssertEqual(
      CoreL10n.text("这条发布记录没有远端 commit，无法执行线上回滚。", locale: english),
      "This release record has no remote commit, so an online rollback cannot be performed."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "仓库 API 请求失败：HTTP %@。%@%@",
        locale: english,
        arguments: ["403", "Check token permissions.", ""]
      ),
      "Repository API request failed: HTTP 403. Check token permissions."
    )
  }

  func testRepositoryPermissionEvidenceCopyResolvesInEnglish() {
    let english = Locale(identifier: "en")

    XCTAssertEqual(
      CoreL10n.format(
        "# %@ Token 权限证据包",
        locale: english,
        arguments: ["GitHub"]
      ),
      "# GitHub Token Permission Evidence"
    )
    XCTAssertEqual(
      CoreL10n.text("# GitHub/GitLab 线上发布核对包", locale: english),
      "# GitHub/GitLab Online Publishing Checklist"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "- 权限检查结论：%@",
        locale: english,
        arguments: ["Token has write access"]
      ),
      "- Permission check result: Token has write access"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "# %@ 线上发布实测包",
        locale: english,
        arguments: ["GitLab"]
      ),
      "# GitLab Online Publishing Verification"
    )
    XCTAssertEqual(
      CoreL10n.text("仓库访问 Token 已保存到 Keychain。", locale: english),
      "Repository access token saved to Keychain."
    )
  }

  func testImageAIAndCredentialFeedbackResolveInEnglish() {
    let english = Locale(identifier: "en")

    XCTAssertEqual(
      CoreL10n.format(
        "正在%@：%d/%d 篇文章。",
        locale: english,
        arguments: ["Compress JPEGs", 2, 5]
      ),
      "Compress JPEGs in progress: 2 of 5 articles."
    )
    XCTAssertEqual(
      CoreL10n.text("AI 正在处理", locale: english),
      "AI is processing"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "已附加图片：%@",
        locale: english,
        arguments: ["cover.png"]
      ),
      "Attached images: cover.png"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "Keychain 操作失败：%@（错误码 %@）",
        locale: english,
        arguments: ["Denied", "-50"]
      ),
      "Keychain operation failed: Denied (error code -50)"
    )
  }

  func testWorkspaceBackupCopyResolvesInEnglish() {
    let english = Locale(identifier: "en")

    XCTAssertEqual(
      CoreL10n.format(
        "已校验 %d 个自动备份；%d 个校验失败",
        locale: english,
        arguments: [3, 1]
      ),
      "Validated 3 automatic backups; 1 failed validation."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "工作区备份完成：%d 篇草稿、%d 个历史版本",
        locale: english,
        arguments: [2, 5]
      ),
      "Workspace backup completed: 2 drafts and 5 historical versions."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "工作区备份清单无效：%@",
        locale: english,
        arguments: ["File count does not match the manifest."]
      ),
      "The workspace backup manifest is invalid: File count does not match the manifest."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "备份文件超过允许大小（%lld MB）：%@",
        locale: english,
        arguments: [Int64(10), "workbench.json"]
      ),
      "A backup file exceeds the allowed size (10 MB): workbench.json"
    )
    XCTAssertEqual(
      CoreL10n.format(
        "实际文件与清单不同；缺少 %@，多出 %@",
        locale: english,
        arguments: ["none", "extra.json"]
      ),
      "Actual files differ from the manifest; missing: none; extra: extra.json."
    )
    XCTAssertEqual(CoreL10n.text("无", locale: english), "none")
    XCTAssertEqual(
      CoreL10n.text("工作区恢复包已安全暂存，应用重新启动后生效", locale: english),
      "The workspace restore package has been safely staged and will take effect after the app restarts."
    )
  }

  func testPublicRiskCategorySurvivesLocalizationAndLegacyDecoding() throws {
    let issue = PreflightIssue(
      severity: .error,
      title: "Localized title",
      message: "Localized message",
      field: "body",
      category: .publicRisk
    )
    XCTAssertTrue(issue.isPublicRiskIssue)

    let encoded = try JSONEncoder().encode(issue)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "category")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let legacyIssue = try JSONDecoder().decode(PreflightIssue.self, from: legacyData)

    XCTAssertNil(legacyIssue.category)
  }
}
