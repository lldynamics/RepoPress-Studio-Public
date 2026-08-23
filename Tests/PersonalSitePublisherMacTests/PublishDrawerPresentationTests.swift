import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class PublishDrawerPresentationTests: XCTestCase {
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
      "没有可发布文章"
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
      "发布所有可发布文章"
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
