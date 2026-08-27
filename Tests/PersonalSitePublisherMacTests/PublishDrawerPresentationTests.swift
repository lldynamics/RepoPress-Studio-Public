import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishDrawerPresentationTests: XCTestCase {
  func testPublishFeedbackPreservesSeverityAndProvidesAccessiblePresentation() {
    let expectations: [(PublishActionMessageStatus, String, String)] = [
      (.information, "信息", "info.circle.fill"),
      (.success, "成功", "checkmark.circle.fill"),
      (.warning, "警告", "exclamationmark.triangle.fill"),
      (.failure, "失败", "xmark.octagon.fill"),
    ]

    for (status, title, systemImage) in expectations {
      XCTAssertEqual(status.publishDrawerTitle, title)
      XCTAssertEqual(status.publishDrawerSystemImage, systemImage)
    }
  }

  func testBatchActionExplainsMissingRepositoryConfiguration() {
    let state = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: false,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4
    )

    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(state))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(state),
      "先配置线上仓库"
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.accessibilityHint(
        isEnabled: false,
        status: PublishDrawerBatchActionPresentation.status(state)
      ),
      "先配置线上仓库"
    )
  }

  func testBatchActionExplainsTokenAndPermissionGates() {
    let missingToken = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: false,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(missingToken),
      "请先保存仓库 Token"
    )

    let unchecked = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .unchecked,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(unchecked),
      "请先检查仓库写入权限"
    )

    let readOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .readOnly,
      publishableArticleCount: 2,
      changedFileCount: 4
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(readOnly),
      "Token 没有仓库写入权限"
    )
  }

  func testBatchActionExplainsEmptyQueueAndBusyStates() {
    let empty = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      changedFileCount: 0
    )
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(empty))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(empty),
      "没有待处理变更"
    )

    let refreshing = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4,
      isPlanRefreshing: true
    )
    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(refreshing))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(refreshing),
      "正在汇总文章发布包"
    )

    let publishing = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4,
      isPublishing: true
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(publishing),
      "正在发布文章"
    )
  }

  func testBatchActionUsesArticleSpecificNameAndEnablesOnlyWhenReady() {
    let ready = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 2,
      changedFileCount: 4
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(ready))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(ready),
      "可发布 2 篇文章 · 4 个文章文件"
    )
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.title,
      "发布所有待处理变更"
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("CSS")
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("模板")
    )
    XCTAssertTrue(
      PublishDrawerBatchActionPresentation.detail.contains("脚本")
    )
  }

  func testBatchActionAllowsCleanupOnlyQueue() {
    let cleanupOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      pendingDeletionCount: 2,
      changedFileCount: 2
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(cleanupOnly))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(cleanupOnly),
      "待下线 2 篇文章 · 2 个文件"
    )
  }

  func testBatchActionSummarizesPublishAndCleanupTogether() {
    let mixed = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 3,
      pendingDeletionCount: 2,
      changedFileCount: 7
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(mixed))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(mixed),
      "可发布 3 篇 · 待下线 2 篇 · 7 个文件"
    )
  }

  func testBatchActionExplainsThatWebsiteDraftsUseSeparateSyncQueue() {
    let draftOnly = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      publishableArticleCount: 0,
      draftSyncArticleCount: 2,
      changedFileCount: 2
    )

    XCTAssertFalse(PublishDrawerBatchActionPresentation.isEnabled(draftOnly))
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(draftOnly),
      "2 篇网站草稿未纳入发布，请单独同步"
    )

    var mixed = draftOnly
    mixed.publishableArticleCount = 1
    XCTAssertEqual(
      PublishDrawerBatchActionPresentation.status(mixed),
      "可发布 1 篇文章 · 2 个文章文件 · 另有 2 篇网站草稿未纳入发布"
    )
  }

  func testSingleWebsiteDraftActionUsesExplicitSyncLanguage() {
    let presentation = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: true
    )

    XCTAssertEqual(presentation.actionTitle, "同步当前网站草稿…")
    XCTAssertEqual(presentation.accessibilityLabel, "同步当前网站草稿")
    XCTAssertTrue(presentation.enabledHint.contains("不会纳入批量正式发布"))
    XCTAssertEqual(
      presentation.confirmationPurpose.confirmationTitle,
      "网站草稿同步确认"
    )
    XCTAssertTrue(
      presentation.confirmationPurpose.confirmationDetail.contains("不会移除 draft 标记")
    )
    XCTAssertEqual(
      presentation.confirmationPurpose.confirmActionTitle,
      "确认同步网站草稿"
    )
  }

  func testSingleFormalArticleActionKeepsPublicationLanguage() {
    let presentation = PublishDrawerSingleArticleActionPresentation.make(
      isWebsiteDraft: false
    )

    XCTAssertEqual(presentation.actionTitle, "仅发布当前文章…")
    XCTAssertEqual(presentation.confirmationPurpose, .publication)
    XCTAssertEqual(presentation.confirmationPurpose.confirmationTitle, "最终发布确认")
  }

  func testPermissionActionUsesDetectedOriginWhenProfileIsMissing() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "",
      detectedOrigin: origin
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "使用 lldynamics/site 并检查权限")
    XCTAssertTrue(presentation.help.contains("lldynamics/site"))
  }

  func testPermissionActionDisablesWhenConfiguredOwnerDoesNotMatchOrigin() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "other-owner",
      configuredRepository: "",
      detectedOrigin: origin
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertTrue(presentation.help.contains("不一致"))
    XCTAssertTrue(presentation.help.contains("修正"))
  }

  func testPermissionActionDisablesWhenConfiguredRepositoryDoesNotMatchOrigin() {
    let origin = RepositoryRemote(
      remoteURL: "git@github.com:lldynamics/site.git",
      provider: .github,
      repositoryBaseURL: "https://api.github.com",
      owner: "lldynamics",
      name: "site"
    )

    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "other-site",
      detectedOrigin: origin
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertTrue(presentation.help.contains("不一致"))
    XCTAssertTrue(presentation.help.contains("完成"))
  }

  func testPermissionActionDisablesWithoutConfiguredRepositoryOrOrigin() {
    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "",
      configuredRepository: "",
      detectedOrigin: nil
    )

    XCTAssertFalse(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "检查权限")
    XCTAssertTrue(presentation.help.contains("先配置仓库"))
  }

  func testPermissionActionKeepsCheckTitleForConfiguredRepository() {
    let presentation = RepositoryPermissionActionPresentation.make(
      configuredOwner: "lldynamics",
      configuredRepository: "site",
      detectedOrigin: nil
    )

    XCTAssertTrue(presentation.isEnabled)
    XCTAssertEqual(presentation.title, "检查权限")
  }

  func testReviewRequestRemoteConflictDoesNotBlockBatchActionPresentation() {
    let state = PublishDrawerBatchActionPresentation.State(
      repositoryConfigured: true,
      hasToken: true,
      permission: .writable,
      hasRemoteConflict: false,
      publishableArticleCount: 1,
      changedFileCount: 1
    )

    XCTAssertTrue(PublishDrawerBatchActionPresentation.isEnabled(state))
  }
}
