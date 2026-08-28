import XCTest
@testable import PublishingWorkbenchCore

final class ReleaseLedgerServiceTests: XCTestCase {
  func testActionKindsExposeDeploymentRecheckCapabilityForActionQueue() {
    XCTAssertTrue(ReleaseLedgerActionKind.failedRelease.supportsDeploymentRecheck)
    XCTAssertTrue(ReleaseLedgerActionKind.retryDeploymentCheck.supportsDeploymentRecheck)
    XCTAssertTrue(ReleaseLedgerActionKind.observeDeployment.supportsDeploymentRecheck)
    XCTAssertTrue(ReleaseLedgerActionKind.recoverPartialRemotePublish.supportsDeploymentRecheck)
    XCTAssertFalse(ReleaseLedgerActionKind.completeReview.supportsDeploymentRecheck)
    XCTAssertFalse(ReleaseLedgerActionKind.publishLocalChanges.supportsDeploymentRecheck)
    XCTAssertFalse(ReleaseLedgerActionKind.keepRollbackReady.supportsDeploymentRecheck)
  }

  func testLedgerClassifiesPendingDeploymentSucceededFailedAndReviewRecords() {
    let profileID = UUID()
    let directRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      changedPaths: ["content/posts/online.md"],
      branchName: "main",
      commitSHA: "abcdef1234567890"
    )
    let failedRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "失败部署",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      changedPaths: ["content/posts/fail.md"],
      branchName: "main",
      commitSHA: "fedcba9876543210"
    )
    let reviewRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteReviewRequest,
      title: "线上 PR",
      summary: "GitHub · publish/post · 1 个文件",
      siteProfileID: profileID,
      changedPaths: ["content/posts/review.md"],
      branchName: "publish/post",
      targetBranch: "main",
      reviewURL: "https://github.com/owner/site/pull/1"
    )
    let localRecord = ReleaseRecord(
      id: UUID(),
      kind: .localWrite,
      title: "本地写入",
      summary: "已写入 1 个文件",
      siteProfileID: profileID,
      changedPaths: ["content/posts/local.md"]
    )
    let failureRecord = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交失败",
      summary: "401",
      siteProfileID: profileID,
      changedPaths: ["content/posts/error.md"]
    )

    let snapshots = [
      directRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: directRecord.id,
        provider: .githubPages,
        level: .success,
        title: "GitHub Pages · 正常",
        message: "站点可访问。",
        siteURLText: "https://example.com",
        signals: [],
        expectedBranch: "main",
        expectedCommitSHA: "abcdef1234567890",
        observedBranch: "main",
        observedCommitSHA: "abcdef1234567890",
        attributionVerified: true
      ),
      failedRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: failedRecord.id,
        provider: .githubPages,
        level: .failed,
        title: "GitHub Pages · 失败",
        message: "Actions 失败。",
        siteURLText: "https://example.com",
        signals: []
      ),
      reviewRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: reviewRecord.id,
        provider: .githubPages,
        level: .success,
        title: "GitHub Pages · 正常",
        message: "主站可访问，但 PR 尚未合并。",
        siteURLText: "https://example.com",
        signals: []
      ),
    ]

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [directRecord, failedRecord, reviewRecord, localRecord, failureRecord],
      deploymentStatusSnapshots: snapshots
    )

    XCTAssertEqual(ledger.entries.first { $0.id == directRecord.id }?.status, .succeeded)
    XCTAssertEqual(ledger.entries.first { $0.id == failedRecord.id }?.status, .failed)
    XCTAssertEqual(ledger.entries.first { $0.id == reviewRecord.id }?.status, .pendingReview)
    XCTAssertNil(ledger.entries.first { $0.id == reviewRecord.id }?.deploymentStatus)
    XCTAssertEqual(ledger.entries.first { $0.id == localRecord.id }?.status, .localOnly)
    XCTAssertEqual(ledger.entries.first { $0.id == failureRecord.id }?.status, .failed)
    XCTAssertEqual(ledger.summary.totalCount, 5)
    XCTAssertEqual(ledger.summary.localPendingCount, 1)
    XCTAssertEqual(ledger.summary.reviewPendingCount, 1)
    XCTAssertEqual(ledger.summary.succeededCount, 1)
    XCTAssertEqual(ledger.summary.failedCount, 2)
    XCTAssertEqual(ledger.deploymentOverview.level, .failed)
    XCTAssertEqual(ledger.deploymentOverview.failedDeploymentCount, 1)
    XCTAssertEqual(ledger.deploymentOverview.checkedRecordCount, 2)
    XCTAssertEqual(ledger.deploymentOverview.uncheckedDeploymentCount, 0)
    XCTAssertEqual(
      ledger.deploymentOverview.message,
      CoreL10n.format("%@ 条部署检查失败，需要查看失败信号后重试。", "1")
    )
  }

  func testWithdrawnReviewIsNotCountedAsOnlineOrScheduledForDeployment() throws {
    let profileID = UUID()
    let withdrawnRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteReviewWithdrawal,
      title: "线上 Review 撤回",
      summary: "GitHub · #9 · closed",
      siteProfileID: profileID,
      draftTitle: "已撤回文章",
      changedPaths: ["content/posts/withdrawn.md"],
      branchName: "publish/withdrawn",
      targetBranch: "main",
      commitSHA: "abcdef1234567890",
      reviewURL: "https://github.com/owner/site/pull/9"
    )
    let misleadingDeploymentSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: withdrawnRecord.id,
      provider: .githubPages,
      level: .success,
      title: "GitHub Pages · 正常",
      message: "主站可访问。",
      siteURLText: "https://example.com",
      signals: []
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [withdrawnRecord],
      deploymentStatusSnapshots: [withdrawnRecord.id: misleadingDeploymentSnapshot]
    )

    let entry = try XCTUnwrap(ledger.entries.first)
    XCTAssertEqual(entry.status, .reviewWithdrawn)
    XCTAssertEqual(entry.statusMessage, "PR/MR 已撤回，未合并到目标分支，也未触发部署。")
    XCTAssertNil(entry.deploymentStatus)
    XCTAssertTrue(ledger.actionItems.isEmpty)
    XCTAssertEqual(ledger.summary.succeededCount, 0)
    XCTAssertEqual(ledger.summary.deploymentPendingCount, 0)
  }

  func testLocalGitCommitStaysLocalAndIgnoresDeploymentSnapshot() throws {
    let profileID = UUID()
    let localCommit = ReleaseRecord(
      id: UUID(),
      kind: .directCommit,
      title: "本地提交",
      summary: "main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "本地提交文章",
      changedPaths: ["content/posts/local-commit.md"],
      branchName: "main",
      commitSHA: "1234567890abcdef"
    )
    let misleadingDeploymentSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: localCommit.id,
      provider: .githubPages,
      level: .success,
      title: "GitHub Pages · 正常",
      message: "主站可访问。",
      siteURLText: "https://example.com",
      signals: []
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [localCommit],
      deploymentStatusSnapshots: [localCommit.id: misleadingDeploymentSnapshot]
    )

    let entry = try XCTUnwrap(ledger.entries.first)
    XCTAssertEqual(entry.status, .localOnly)
    XCTAssertEqual(entry.statusMessage, "内容已在本地提交，尚未推送到远端，也未触发部署。")
    XCTAssertNil(entry.deploymentStatus)
    XCTAssertEqual(ledger.summary.localPendingCount, 1)
    XCTAssertEqual(ledger.summary.succeededCount, 0)
    XCTAssertEqual(ledger.summary.deploymentPendingCount, 0)
  }

  func testRemotePreviewBranchIsNotCountedAsOnlineOrDeployed() throws {
    let profileID = UUID()
    let previewRecord = ReleaseRecord(
      id: UUID(),
      kind: .remotePreviewBranch,
      title: "远端预览分支：预览文章",
      summary: "GitHub · draft/preview · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "预览文章",
      changedPaths: ["content/posts/preview.md"],
      branchName: "draft/preview",
      targetBranch: "main",
      commitSHA: "preview1234567890"
    )
    let misleadingDeploymentSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: previewRecord.id,
      provider: .githubPages,
      level: .success,
      title: "GitHub Pages · 正常",
      message: "主站可访问。",
      siteURLText: "https://example.com",
      signals: []
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [previewRecord],
      deploymentStatusSnapshots: [previewRecord.id: misleadingDeploymentSnapshot]
    )

    let entry = try XCTUnwrap(ledger.entries.first)
    XCTAssertEqual(entry.status, .previewOnly)
    XCTAssertEqual(entry.statusMessage, "预览分支已推送，未合并到正式分支，也未触发正式部署。")
    XCTAssertNil(entry.deploymentStatus)
    XCTAssertTrue(ledger.actionItems.isEmpty)
    XCTAssertEqual(ledger.summary.succeededCount, 0)
    XCTAssertEqual(ledger.summary.deploymentPendingCount, 0)
  }

  func testReleaseLedgerOperationLogMarkdownExportsWholeLedgerForHandoff() throws {
    let profileID = UUID()
    let failedRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "失败部署",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      siteName: "个人网站",
      draftTitle: "失败文章",
      markdownPath: "content/posts/fail.md",
      changedPaths: ["content/posts/fail.md", "static/images/fail.jpg"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "fedcba9876543210",
      createdAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let reviewRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteReviewRequest,
      title: "线上 PR",
      summary: "GitHub · publish/post · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "Review 文章",
      markdownPath: "content/posts/review.md",
      changedPaths: ["content/posts/review.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/post",
      targetBranch: "main",
      reviewURL: "https://github.com/owner/site/pull/12",
      createdAt: Date(timeIntervalSince1970: 1_900_000_100)
    )
    let snapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: failedRecord.id,
      provider: .githubPages,
      level: .failed,
      title: "GitHub Pages · 失败",
      message: "Actions 失败。",
      siteURLText: "https://owner.github.io/site/",
      checkedAt: Date(timeIntervalSince1970: 1_900_000_200),
      signals: [
        DeploymentStatusSignal(
          level: .failed,
          title: "GitHub Actions",
          message: "completed / failure",
          urlText: "https://github.com/owner/site/actions/runs/99"
        )
      ]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [reviewRecord, failedRecord],
      deploymentStatusSnapshots: [failedRecord.id: snapshot]
    )
    let markdown = ledger.operationLogMarkdown

    XCTAssertTrue(markdown.contains(CoreL10n.text("# 发布台账")))
    XCTAssertTrue(markdown.contains(CoreL10n.text("## 总览")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 发布记录：%@", "2")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 待处理：%@", "2")))
    XCTAssertTrue(markdown.contains(CoreL10n.text("## 部署态势")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- 状态：%@", CoreL10n.text("有部署失败"))))
    XCTAssertTrue(markdown.contains(CoreL10n.text("### 重点部署信号")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("- [%@] %@：%@", CoreL10n.text("失败"), "GitHub Actions", "completed / failure")))
    XCTAssertTrue(markdown.contains("https://github.com/owner/site/actions/runs/99"))
    XCTAssertTrue(markdown.contains(CoreL10n.text("## 行动队列")))
    XCTAssertTrue(markdown.contains(CoreL10n.format(
      "- [%@] %@：%@",
      CoreL10n.text("高"),
      CoreL10n.text("失败处理"),
      CoreL10n.format("处理失败发布：%@", "失败文章")
    )))
    XCTAssertTrue(markdown.contains("git revert --no-edit 'fedcba9876543210'"))
    XCTAssertTrue(markdown.contains(CoreL10n.format(
      "- [%@] %@：%@",
      CoreL10n.text("中"),
      CoreL10n.text("合并 Review"),
      CoreL10n.format("处理 Review：%@", "Review 文章")
    )))
    XCTAssertTrue(markdown.contains(CoreL10n.text("## 发布记录")))
    XCTAssertTrue(markdown.contains("- 失败部署"))
    XCTAssertTrue(markdown.contains(CoreL10n.format("  - 状态：%@", CoreL10n.text("失败"))))
    XCTAssertTrue(markdown.contains(CoreL10n.format("  - 路径：%@", "content/posts/fail.md")))
    XCTAssertTrue(markdown.contains(CoreL10n.format(
      "  - 变更文件：%@",
      ["content/posts/fail.md", "static/images/fail.jpg"].joined(separator: CoreL10n.text("、"))
    )))
    XCTAssertTrue(markdown.contains(CoreL10n.format("  - 部署：%@ - %@", "GitHub Pages · 失败", "Actions 失败。")))
    XCTAssertTrue(markdown.contains(CoreL10n.format("  - 回滚 PR/MR：%@", "https://github.com/owner/site/compare/main...rollback/fedcba98?")))
    XCTAssertTrue(markdown.contains("- 线上 PR"))
    XCTAssertTrue(markdown.contains(CoreL10n.format("  - PR/MR：%@", "https://github.com/owner/site/pull/12")))
  }

  func testReleaseLedgerActionItemsPrioritizeFailuresAndPendingRecovery() {
    let profileID = UUID()
    let failedRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "失败部署",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "失败文章",
      changedPaths: ["content/posts/fail.md"],
      branchName: "main",
      commitSHA: "fedcba9876543210",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let retryRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "离线检查",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "离线文章",
      changedPaths: ["content/posts/offline.md"],
      branchName: "main",
      commitSHA: "abcdef1234567890",
      createdAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let reviewRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteReviewRequest,
      title: "线上 PR",
      summary: "GitHub · publish/post · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "Review 文章",
      changedPaths: ["content/posts/review.md"],
      branchName: "publish/post",
      reviewURL: "https://github.com/owner/site/pull/2",
      createdAt: Date(timeIntervalSince1970: 1_800_000_200)
    )
    let localRecord = ReleaseRecord(
      id: UUID(),
      kind: .localWrite,
      title: "本地写入",
      summary: "已写入 1 个文件",
      siteProfileID: profileID,
      draftTitle: "本地文章",
      changedPaths: ["content/posts/local.md"],
      createdAt: Date(timeIntervalSince1970: 1_800_000_300)
    )
    let succeededRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "成功文章",
      changedPaths: ["content/posts/success.md"],
      branchName: "main",
      commitSHA: "1111111111111111",
      createdAt: Date(timeIntervalSince1970: 1_800_000_400)
    )

    let snapshots = [
      failedRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: failedRecord.id,
        provider: .githubPages,
        level: .failed,
        title: "GitHub Pages · 失败",
        message: "Actions 失败。",
        siteURLText: "https://example.com",
        signals: []
      ),
      retryRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: retryRecord.id,
        provider: .githubPages,
        level: .unknown,
        title: "GitHub Pages · 未知",
        message: "网络连接不可用。",
        siteURLText: "https://example.com",
        signals: []
      ),
      succeededRecord.id: DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: succeededRecord.id,
        provider: .githubPages,
        level: .success,
        title: "GitHub Pages · 正常",
        message: "站点可访问。",
        siteURLText: "https://example.com",
        signals: [],
        expectedBranch: "main",
        expectedCommitSHA: "1111111111111111",
        observedBranch: "main",
        observedCommitSHA: "1111111111111111",
        attributionVerified: true
      ),
    ]

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [failedRecord, retryRecord, reviewRecord, localRecord, succeededRecord],
      deploymentStatusSnapshots: snapshots
    )

    XCTAssertEqual(ledger.summary.actionItemCount, 5)
    XCTAssertEqual(ledger.actionItems.first?.kind, .retryDeploymentCheck)
    XCTAssertEqual(ledger.actionItems.first?.priority, .high)
    XCTAssertTrue(ledger.actionItems.contains { $0.kind == .failedRelease && $0.recordID == failedRecord.id })
    XCTAssertTrue(ledger.actionItems.contains { $0.kind == .completeReview && $0.remoteURL == "https://github.com/owner/site/pull/2" })
    XCTAssertTrue(ledger.actionItems.contains {
      $0.kind == .publishLocalChanges
        && $0.commandLines == [
          "if git cat-file -e HEAD:'content/posts/local.md' >/dev/null 2>&1; then git restore --source=HEAD --staged --worktree -- 'content/posts/local.md'; else git restore --staged -- 'content/posts/local.md' >/dev/null 2>&1 || true; git clean -fd -- 'content/posts/local.md'; fi"
        ]
    })
    XCTAssertTrue(ledger.actionItems.contains { $0.kind == .keepRollbackReady && $0.priority == .low })
  }

  func testReleaseLedgerReturnsEveryActionItemBeyondTwelveInStablePriorityOrder() {
    let profileID = UUID()
    let baseTimestamp = 1_900_000_000.0

    let highPriorityRecords = (0..<3).map { index in
      ReleaseRecord(
        id: UUID(),
        kind: .remoteDirectCommit,
        title: "失败部署 \(index)",
        summary: "GitHub · main",
        siteProfileID: profileID,
        draftTitle: "高优先级文章 \(index)",
        changedPaths: ["content/posts/high-\(index).md"],
        branchName: "main",
        commitSHA: "high-\(index)",
        createdAt: Date(timeIntervalSince1970: baseTimestamp + Double(index))
      )
    }
    let mediumPriorityRecords = (0..<10).map { index in
      ReleaseRecord(
        id: UUID(),
        kind: .localWrite,
        title: "本地写入 \(index)",
        summary: "已写入 1 个文件",
        siteProfileID: profileID,
        draftTitle: "中优先级文章 \(index)",
        changedPaths: ["content/posts/medium-\(index).md"],
        createdAt: Date(timeIntervalSince1970: baseTimestamp + 100 + Double(index))
      )
    }
    let lowPriorityRecords = (0..<2).map { index in
      ReleaseRecord(
        id: UUID(),
        kind: .remoteDirectCommit,
        title: "成功部署 \(index)",
        summary: "GitHub · main",
        siteProfileID: profileID,
        draftTitle: "低优先级文章 \(index)",
        changedPaths: ["content/posts/low-\(index).md"],
        branchName: "main",
        commitSHA: "low-\(index)",
        createdAt: Date(timeIntervalSince1970: baseTimestamp + 200 + Double(index))
      )
    }

    var snapshots: [UUID: DeploymentStatusSnapshot] = [:]
    for record in highPriorityRecords {
      snapshots[record.id] = DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: record.id,
        provider: .githubPages,
        level: .failed,
        title: "GitHub Pages · 失败",
        message: "Actions 失败。",
        siteURLText: "https://example.com",
        signals: []
      )
    }
    for record in lowPriorityRecords {
      snapshots[record.id] = DeploymentStatusSnapshot(
        profileID: profileID,
        releaseRecordID: record.id,
        provider: .githubPages,
        level: .success,
        title: "GitHub Pages · 正常",
        message: "站点可访问。",
        siteURLText: "https://example.com",
        signals: [],
        expectedBranch: "main",
        expectedCommitSHA: record.commitSHA,
        observedBranch: "main",
        observedCommitSHA: record.commitSHA,
        attributionVerified: true
      )
    }

    let records = Array(
      (mediumPriorityRecords + lowPriorityRecords + highPriorityRecords).reversed()
    )
    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: records,
      deploymentStatusSnapshots: snapshots
    )
    let expectedRecordIDs =
      highPriorityRecords.reversed().map(\.id)
      + mediumPriorityRecords.reversed().map(\.id)
      + lowPriorityRecords.reversed().map(\.id)

    XCTAssertEqual(ledger.actionItems.count, 15)
    XCTAssertEqual(ledger.summary.actionItemCount, 15)
    XCTAssertEqual(ledger.actionItems.map(\.recordID), expectedRecordIDs)
    XCTAssertEqual(ledger.actionItems.map(\.priority), [
      .high, .high, .high,
      .medium, .medium, .medium, .medium, .medium,
      .medium, .medium, .medium, .medium, .medium,
      .low, .low,
    ])
  }

  func testDeploymentOverviewHighlightsPendingAndActionableSignals() {
    let profileID = UUID()
    let pendingRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "待检查部署",
      summary: "GitHub · main",
      siteProfileID: profileID,
      branchName: "main",
      commitSHA: "abc123"
    )
    let runningRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "运行中部署",
      summary: "GitHub · main",
      siteProfileID: profileID,
      branchName: "main",
      commitSHA: "def456"
    )
    let checkedAt = Date(timeIntervalSince1970: 1_900_000_000)
    let runningSignal = DeploymentStatusSignal(
      level: .running,
      title: "GitHub Actions",
      message: "workflow 仍在运行。"
    )
    let runningSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: runningRecord.id,
      provider: .githubPages,
      level: .running,
      title: "GitHub Pages · 部署中",
      message: "Actions 正在运行。",
      siteURLText: "https://example.com",
      checkedAt: checkedAt,
      signals: [runningSignal]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [pendingRecord, runningRecord],
      deploymentStatusSnapshots: [runningRecord.id: runningSnapshot]
    )

    XCTAssertEqual(ledger.deploymentOverview.level, .running)
    XCTAssertEqual(ledger.deploymentOverview.runningDeploymentCount, 1)
    XCTAssertEqual(ledger.deploymentOverview.uncheckedDeploymentCount, 1)
    XCTAssertEqual(ledger.deploymentOverview.lastCheckedAt, checkedAt)
    XCTAssertEqual(ledger.deploymentOverview.highlightedSignals, [runningSignal])
    XCTAssertEqual(ledger.deploymentOverview.nextActionTitle, CoreL10n.text("继续观察部署"))
  }

  func testUnknownDeploymentCheckBecomesRetryablePendingState() {
    let profileID = UUID()
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      changedPaths: ["content/posts/offline.md"],
      branchName: "main",
      commitSHA: "abcdef1234567890"
    )
    let snapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: record.id,
      provider: .githubPages,
      level: .unknown,
      title: "GitHub Pages · 未知",
      message: "读取 Actions 状态失败：网络连接不可用。",
      siteURLText: "https://example.com",
      signals: [
        DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub Actions",
          message: "读取 Actions 状态失败：网络连接不可用。"
        )
      ]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [record.id: snapshot]
    )
    let entry = ledger.entries.first

    XCTAssertEqual(entry?.status, .pendingRetry)
    XCTAssertEqual(entry?.statusMessage, "读取 Actions 状态失败：网络连接不可用。")
    XCTAssertEqual(ledger.summary.deploymentPendingCount, 1)
    XCTAssertEqual(ledger.summary.failedCount, 0)
  }

  func testPartialRemotePublishFailureBecomesPendingRecoveryState() throws {
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "GitHub 直接提交部分完成后失败：1 个文件已写入 main，最后 commit：abcdef12。网络连接不可用。",
      siteProfileID: UUID(),
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [:]
    )
    let entry = try XCTUnwrap(ledger.entries.first)
    let action = try XCTUnwrap(ledger.actionItems.first)

    XCTAssertEqual(entry.status, .pendingRemoteRecovery)
    XCTAssertEqual(ledger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(ledger.summary.failedCount, 0)
    XCTAssertEqual(ledger.deploymentOverview.level, .unknown)
    XCTAssertEqual(ledger.deploymentOverview.title, CoreL10n.text("有远端恢复待确认"))
    XCTAssertEqual(
      ledger.deploymentOverview.message,
      CoreL10n.format("%@ 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。", "1")
    )
    XCTAssertEqual(ledger.deploymentOverview.nextActionTitle, CoreL10n.text("确认远端恢复"))
    XCTAssertEqual(
      ledger.deploymentOverview.nextActionMessage,
      CoreL10n.text("打开恢复包里的远端链接，确认已写入文件和 commit，再选择重试部署检查或发起回滚 PR/MR。")
    )
    XCTAssertEqual(action.kind, .recoverPartialRemotePublish)
    XCTAssertEqual(action.priority, .high)
    XCTAssertEqual(action.remoteURL, "https://github.com/owner/site/commit/abcdef1234567890")
    XCTAssertTrue(action.commandLines.contains("git revert --no-edit 'abcdef1234567890'"))
    XCTAssertTrue(action.commandLines.contains("git push origin 'rollback/abcdef12'"))
  }

  func testPartialRemotePublishFailureKeepsRecoveryStateEvenWhenDeploymentResponds() throws {
    let profileID = UUID()
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "1 个文件已写入 main，但后续文件提交失败。",
      siteProfileID: profileID,
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    let deployment = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: record.id,
      provider: .githubPages,
      level: .success,
      title: "GitHub Pages · 正常",
      message: "站点可访问。",
      siteURLText: "https://owner.github.io/site/",
      signals: [],
      expectedBranch: "main",
      expectedCommitSHA: "abcdef1234567890",
      observedBranch: "main",
      observedCommitSHA: "abcdef1234567890",
      attributionVerified: true
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [record.id: deployment]
    )
    let entry = try XCTUnwrap(ledger.entries.first)

    XCTAssertEqual(entry.status, .pendingRemoteRecovery)
    XCTAssertEqual(entry.deploymentStatus?.level, .success)
    XCTAssertEqual(ledger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(ledger.summary.succeededCount, 0)
    XCTAssertEqual(ledger.deploymentOverview.title, CoreL10n.text("有远端恢复待确认"))
    XCTAssertEqual(ledger.deploymentOverview.nextActionTitle, CoreL10n.text("确认远端恢复"))
    XCTAssertEqual(ledger.actionItems.first?.kind, .recoverPartialRemotePublish)
  }

  func testPartialRemotePublishFailureKeepsRecoveryOverviewAboveRunningDeployment() throws {
    let profileID = UUID()
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "远端 commit 已写入，但发布确认中断。",
      siteProfileID: profileID,
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .gitlab,
      repositoryBaseURL: "https://gitlab.com/api/v4",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "fedcba9876543210"
    )
    let runningSignal = DeploymentStatusSignal(
      level: .running,
      title: "GitLab Pipeline",
      message: "running",
      urlText: "https://gitlab.com/owner/site/-/pipelines/123"
    )
    let deployment = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: record.id,
      provider: .gitlabPages,
      level: .running,
      title: "GitLab Pipeline · 运行中",
      message: "Pipeline 仍在运行。",
      siteURLText: nil,
      signals: [runningSignal]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [record.id: deployment]
    )
    let entry = try XCTUnwrap(ledger.entries.first)

    XCTAssertEqual(entry.status, .pendingRemoteRecovery)
    XCTAssertEqual(entry.deploymentStatus?.level, .running)
    XCTAssertEqual(ledger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(ledger.summary.deploymentPendingCount, 0)
    XCTAssertEqual(ledger.deploymentOverview.title, CoreL10n.text("有远端恢复待确认"))
    XCTAssertEqual(
      ledger.deploymentOverview.message,
      CoreL10n.format("%@ 条远端发布部分完成后中断，需要确认 commit、Review 或回滚方案。", "1")
    )
    XCTAssertEqual(ledger.deploymentOverview.nextActionTitle, CoreL10n.text("确认远端恢复"))
    XCTAssertEqual(ledger.deploymentOverview.runningDeploymentCount, 1)
    XCTAssertEqual(ledger.deploymentOverview.highlightedSignals, [runningSignal])
    XCTAssertEqual(ledger.actionItems.first?.kind, .recoverPartialRemotePublish)
  }

  func testActionItemsOpenDeploymentDiagnosticSignalBeforeRollbackTarget() throws {
    let profileID = UUID()
    let failedRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "失败部署",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "失败文章",
      changedPaths: ["content/posts/fail.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "fedcba9876543210"
    )
    let retryRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "待重试部署",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      draftTitle: "离线文章",
      changedPaths: ["content/posts/offline.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "abcdef1234567890"
    )
    let failedSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: failedRecord.id,
      provider: .githubPages,
      level: .failed,
      title: "GitHub Pages · 失败",
      message: "Actions 失败。",
      siteURLText: "https://owner.github.io/site/",
      signals: [
        DeploymentStatusSignal(
          level: .failed,
          title: "GitHub Actions",
          message: "completed / failure",
          urlText: "https://github.com/owner/site/actions/runs/99"
        )
      ]
    )
    let retrySnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: retryRecord.id,
      provider: .githubPages,
      level: .unknown,
      title: "GitHub Pages · 未知",
      message: "读取 Actions 状态失败：网络连接不可用。",
      siteURLText: "https://owner.github.io/site/",
      signals: [
        DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub Actions",
          message: "读取 Actions 状态失败：网络连接不可用。",
          urlText: "https://github.com/owner/site/actions"
        )
      ]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [failedRecord, retryRecord],
      deploymentStatusSnapshots: [
        failedRecord.id: failedSnapshot,
        retryRecord.id: retrySnapshot,
      ]
    )

    let failedAction = try XCTUnwrap(
      ledger.actionItems.first { $0.kind == .failedRelease && $0.recordID == failedRecord.id }
    )
    let retryAction = try XCTUnwrap(
      ledger.actionItems.first { $0.kind == .retryDeploymentCheck && $0.recordID == retryRecord.id }
    )

    XCTAssertEqual(failedAction.remoteURL, "https://github.com/owner/site/actions/runs/99")
    XCTAssertEqual(retryAction.remoteURL, "https://github.com/owner/site/actions")
    XCTAssertTrue(failedAction.commandLines.contains("git revert --no-edit 'fedcba9876543210'"))
  }

  func testRecoveryPackageCombinesDeploymentSignalsAndRollbackCommands() throws {
    let profileID = UUID()
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交",
      summary: "GitHub · main · 1 个文件",
      siteProfileID: profileID,
      siteName: "个人网站",
      draftTitle: "失败文章",
      markdownPath: "content/posts/fail.md",
      changedPaths: ["content/posts/fail.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "fedcba9876543210",
      createdAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let snapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: record.id,
      provider: .githubPages,
      level: .failed,
      title: "GitHub Pages · 失败",
      message: "Actions 失败。",
      siteURLText: "https://owner.github.io/site/",
      checkedAt: Date(timeIntervalSince1970: 1_900_000_100),
      signals: [
        DeploymentStatusSignal(
          level: .failed,
          title: "GitHub Actions",
          message: "completed / failure",
          urlText: "https://github.com/owner/site/actions/runs/99"
        )
      ]
    )

    let entry = try XCTUnwrap(
      ReleaseLedgerService()
        .ledger(releaseRecords: [record], deploymentStatusSnapshots: [record.id: snapshot])
        .entries
        .first
    )
    let package = entry.recoveryPackage

    XCTAssertEqual(package.status, .failed)
    XCTAssertEqual(package.remoteURL, "https://github.com/owner/site/actions/runs/99")
    XCTAssertTrue(package.rollbackReviewURL?.hasPrefix("https://github.com/owner/site/compare/main...rollback/fedcba98?") == true)
    XCTAssertTrue(package.commandLines.contains("git revert --no-edit 'fedcba9876543210'"))
    XCTAssertEqual(package.reviewTitle, CoreL10n.format("回滚：%@", "失败文章"))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("先打开远端诊断链接定位失败的 Actions、Pipeline 或状态端点。")))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("修复失败原因后重新执行部署检查。")))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("如果不准备继续修复，使用回滚命令和 PR/MR 草稿撤销本次发布。")))
    XCTAssertTrue(package.clipboardMarkdown.contains("# \(CoreL10n.format("发布恢复包：%@", "失败文章"))"))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- 状态：%@", CoreL10n.text("失败"))))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- 远端诊断：%@", "https://github.com/owner/site/actions/runs/99")))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- 回滚 PR/MR：%@", "https://github.com/owner/site/compare/main...rollback/fedcba98?")))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.text("### 发布后校验清单")))
    XCTAssertTrue(package.clipboardMarkdown.contains(
      CoreL10n.format("- [%@] %@：%@", "x", CoreL10n.text("站点入口"), CoreL10n.text("已记录发布后的站点 URL。"))
    ))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- [%@] %@：%@", " ", "GitHub Actions", "completed / failure")))
    XCTAssertTrue(package.clipboardMarkdown.contains(
      CoreL10n.format("- [%@] %@：%@", " ", CoreL10n.text("文章页面校验"), CoreL10n.text("这条发布记录还没有完成文章页面内容校验；需要站点 URL 和文章路径。"))
    ))
    XCTAssertTrue(package.clipboardMarkdown.contains(
      CoreL10n.format("- [%@] %@：%@", " ", CoreL10n.text("处理失败后重试"), CoreL10n.text("打开失败的 Actions、Pipeline 或状态端点，修复后重新检查部署。"))
    ))
    XCTAssertTrue(package.clipboardMarkdown.contains(
      CoreL10n.format("- [%@] %@：%@", CoreL10n.text("失败"), "GitHub Actions", "completed / failure")
    ))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.text("## 下一步清单")))
    XCTAssertTrue(package.clipboardMarkdown.contains("- [ ] \(CoreL10n.text("修复失败原因后重新执行部署检查。"))"))
    XCTAssertTrue(package.clipboardMarkdown.contains("```bash"))
    XCTAssertTrue(package.clipboardMarkdown.contains("git revert --no-edit 'fedcba9876543210'"))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.text("## 回滚 PR/MR 草稿")))
  }

  func testRecoveryPackageBuildsExternalVerificationEvidenceSummary() throws {
    let profileID = UUID()
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "1 个文件已写入 main，部署检查暂时离线。",
      siteProfileID: profileID,
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    let snapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: record.id,
      provider: .githubPages,
      level: .unknown,
      title: "GitHub Actions · 未知",
      message: "网络连接不可用，稍后重试。",
      siteURLText: "https://owner.github.io/site/",
      signals: [
        DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub Actions",
          message: "API request timed out",
          urlText: "https://github.com/owner/site/actions"
        )
      ]
    )

    let entry = try XCTUnwrap(
      ReleaseLedgerService()
        .ledger(releaseRecords: [record], deploymentStatusSnapshots: [record.id: snapshot])
        .entries
        .first
    )
    let evidence = entry.recoveryPackage.externalVerificationEvidenceMarkdown

    XCTAssertTrue(evidence.contains("Remote conflict preview:"))
    XCTAssertTrue(evidence.contains("Pending/offline state:"))
    XCTAssertTrue(evidence.contains("Deployment retry:"))
    XCTAssertTrue(evidence.contains("Rollback package:"))
    XCTAssertTrue(evidence.contains("content/posts/partial.md"))
    XCTAssertTrue(evidence.contains("https://github.com/owner/site/actions"))
    XCTAssertTrue(evidence.contains("git revert --no-edit 'abcdef1234567890'"))
    XCTAssertTrue(evidence.contains("https://github.com/owner/site/compare/main...rollback/abcdef12?"))
  }

  func testRemoteRecoveryVerificationDraftCombinesConflictRetryAndRollbackEvidence() throws {
    let profileID = UUID()
    let partialRecord = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "1 个文件已写入 main，部署检查暂时离线。",
      siteProfileID: profileID,
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    let retryRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交待重试",
      summary: "部署检查暂时离线。",
      siteProfileID: profileID,
      draftTitle: "待重试文章",
      changedPaths: ["content/posts/retry.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "1111222233334444"
    )
    let failedRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "线上提交失败",
      summary: "Actions 失败。",
      siteProfileID: profileID,
      draftTitle: "失败文章",
      changedPaths: ["content/posts/fail.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "fedcba9876543210"
    )
    let retrySnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: retryRecord.id,
      provider: .githubPages,
      level: .unknown,
      title: "GitHub Actions · 未知",
      message: "网络连接不可用，稍后重试。",
      siteURLText: "https://owner.github.io/site/",
      signals: [
        DeploymentStatusSignal(
          level: .unknown,
          title: "GitHub Actions",
          message: "API request timed out",
          urlText: "https://github.com/owner/site/actions"
        )
      ]
    )
    let failedSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: failedRecord.id,
      provider: .githubPages,
      level: .failed,
      title: "GitHub Actions · 失败",
      message: "Actions 失败。",
      siteURLText: "https://owner.github.io/site/",
      signals: [
        DeploymentStatusSignal(
          level: .failed,
          title: "GitHub Actions",
          message: "completed / failure",
          urlText: "https://github.com/owner/site/actions/runs/99"
        )
      ]
    )

    let ledger = ReleaseLedgerService().ledger(
      releaseRecords: [partialRecord, retryRecord, failedRecord],
      deploymentStatusSnapshots: [
        retryRecord.id: retrySnapshot,
        failedRecord.id: failedSnapshot,
      ]
    )
    let draft = ledger.remoteRecoveryVerificationDraftMarkdown

    XCTAssertTrue(draft.contains(CoreL10n.text("# 远端恢复外部验收草稿")))
    XCTAssertTrue(draft.contains(CoreL10n.text("- 状态：草稿；需用一次真实 GitHub/GitLab 远端发布、部署检查和回滚演练补齐，不要直接当作完成证据。")))
    XCTAssertTrue(draft.contains("REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY=Remote conflict preview:"))
    XCTAssertTrue(draft.contains("REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY=Pending/offline state:"))
    XCTAssertTrue(draft.contains("REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY=Deployment retry:"))
    XCTAssertTrue(draft.contains("REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY=Rollback package:"))
    XCTAssertTrue(draft.contains("content/posts/partial.md"))
    XCTAssertTrue(draft.contains("content/posts/retry.md"))
    XCTAssertTrue(draft.contains("https://github.com/owner/site/actions"))
    XCTAssertTrue(draft.contains("git revert --no-edit 'abcdef1234567890'"))
    XCTAssertTrue(draft.contains("https://github.com/owner/site/compare/main...rollback/abcdef12?"))
    XCTAssertTrue(draft.contains(CoreL10n.text("- 只有在四项都来自真实远端结果时，才运行 remote-recovery 外部验收脚本并记录证据。")))
  }

  func testRecoveryPackageForPartialRemotePublishUsesCommitRecoveryTarget() throws {
    let record = ReleaseRecord(
      id: UUID(),
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "网络连接不可用。",
      siteProfileID: UUID(),
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )

    let entry = try XCTUnwrap(
      ReleaseLedgerService()
        .ledger(releaseRecords: [record], deploymentStatusSnapshots: [:])
        .entries
        .first
    )
    let package = entry.recoveryPackage

    XCTAssertEqual(entry.status, .pendingRemoteRecovery)
    XCTAssertEqual(package.status, .pendingRemoteRecovery)
    XCTAssertEqual(package.remoteURL, "https://github.com/owner/site/commit/abcdef1234567890")
    XCTAssertTrue(package.rollbackReviewURL?.hasPrefix("https://github.com/owner/site/compare/main...rollback/abcdef12?") == true)
    let confirmCommitAction = CoreL10n.format("先确认远端 commit %@ 是否已经写入目标分支。", "abcdef12")
    XCTAssertTrue(package.nextActions.contains(confirmCommitAction))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("逐项核对恢复包中的变更文件，确认是否需要保留、重试或回滚。")))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("打开远端诊断链接确认最新 Actions、Pipeline、commit 或分支状态。")))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("如远端状态不可接受，使用回滚命令创建回滚分支并发起 PR/MR。")))
    XCTAssertTrue(package.nextActions.contains(CoreL10n.text("完成确认后重新执行部署检查，直到发布记录转为已上线或失败。")))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- 状态：%@", CoreL10n.text("远端待确认"))))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- Commit：%@", "abcdef1234567890")))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.format("- 回滚 PR/MR：%@", "https://github.com/owner/site/compare/main...rollback/abcdef12?")))
    XCTAssertTrue(package.clipboardMarkdown.contains(CoreL10n.text("## 下一步清单")))
    XCTAssertTrue(package.clipboardMarkdown.contains("- [ ] \(confirmCommitAction)"))
    XCTAssertTrue(package.clipboardMarkdown.contains("- content/posts/partial.md"))
    XCTAssertTrue(package.clipboardMarkdown.contains("git revert --no-edit 'abcdef1234567890'"))
  }

  func testRecoveryPackageDecodesLegacyPayloadWithoutNextActions() throws {
    let data = """
    {
      "title": "发布恢复包：旧记录",
      "status": "pendingRetry",
      "summary": "部署检查暂时无法确认。",
      "remoteURL": "https://github.com/owner/site/actions",
      "commandLines": [],
      "changedPaths": ["content/posts/legacy.md"],
      "clipboardMarkdown": "# 发布恢复包"
    }
    """.data(using: .utf8)!

    let package = try JSONDecoder.workbench.decode(ReleaseRecoveryPackage.self, from: data)

    XCTAssertEqual(package.status, .pendingRetry)
    XCTAssertEqual(package.nextActions, [])
    XCTAssertEqual(package.changedPaths, ["content/posts/legacy.md"])
  }

  func testRollbackDraftsUseCommitReviewAndLocalRecoveryPlans() throws {
    let service = ReleaseLedgerService()
    let commitRecord = ReleaseRecord(
      kind: .directCommit,
      title: "直接提交",
      summary: "main · 1 个文件 · abcdef12",
      draftTitle: "可回滚文章",
      changedPaths: ["content/posts/post.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      commitSHA: "abcdef1234567890"
    )
    let reviewRecord = ReleaseRecord(
      kind: .remoteReviewRequest,
      title: "线上 PR",
      summary: "GitHub · publish/post · 1 个文件",
      draftTitle: "Review 文章",
      changedPaths: ["content/posts/review.md"],
      branchName: "publish/post",
      reviewURL: "https://github.com/owner/site/pull/8"
    )
    let localRecord = ReleaseRecord(
      kind: .localWrite,
      title: "本地写入",
      summary: "已写入 1 个文件",
      draftTitle: "本地文章",
      changedPaths: ["content/posts/local.md"]
    )

    let commitRollback = try XCTUnwrap(service.rollbackDraft(for: commitRecord))
    XCTAssertTrue(commitRollback.summary.contains("rollback/abcdef12"))
    XCTAssertTrue(commitRollback.commandLines.contains("git revert --no-edit 'abcdef1234567890'"))
    XCTAssertTrue(commitRollback.commandLines.contains("git checkout -b 'rollback/abcdef12'"))
    XCTAssertTrue(commitRollback.commandLines.contains("git push origin 'rollback/abcdef12'"))
    XCTAssertFalse(commitRollback.commandLines.contains("git push origin 'main'"))
    XCTAssertEqual(commitRollback.remoteURL, "https://github.com/owner/site/commit/abcdef1234567890")
    XCTAssertEqual(commitRollback.reviewBranchName, "rollback/abcdef12")
    XCTAssertEqual(commitRollback.reviewTitle, CoreL10n.format("回滚：%@", "可回滚文章"))
    XCTAssertTrue(commitRollback.reviewURL?.hasPrefix("https://github.com/owner/site/compare/main...rollback/abcdef12?") == true)
    XCTAssertTrue(commitRollback.reviewURL?.contains("quick_pull=1") == true)
    XCTAssertEqual(
      URLComponents(string: try XCTUnwrap(commitRollback.reviewURL))?.queryItems?.first { $0.name == "title" }?.value,
      commitRollback.reviewTitle
    )
    XCTAssertTrue(commitRollback.reviewBody?.contains(CoreL10n.format("撤销 %@ 在 %@ 上的提交。", "abcdef1234567890", "main")) == true)
    XCTAssertTrue(commitRollback.reviewBody?.contains("- content/posts/post.md") == true)

    let reviewRollback = try XCTUnwrap(service.rollbackDraft(for: reviewRecord))
    XCTAssertEqual(reviewRollback.reviewURL, "https://github.com/owner/site/pull/8")
    XCTAssertEqual(reviewRollback.remoteURL, "https://github.com/owner/site/pull/8")
    XCTAssertEqual(reviewRollback.reviewTitle, CoreL10n.format("关闭发布 Review：%@", "Review 文章"))
    XCTAssertTrue(reviewRollback.reviewBody?.contains(CoreL10n.text("- [ ] 确认 Review 分支尚未合并。")) == true)
    XCTAssertEqual(
      reviewRollback.commandLines.first,
      CoreL10n.format("打开 Review 并关闭：%@", "https://github.com/owner/site/pull/8")
    )

    let localRollback = try XCTUnwrap(service.rollbackDraft(for: localRecord))
    XCTAssertEqual(localRollback.commandLines, [
      "if git cat-file -e HEAD:'content/posts/local.md' >/dev/null 2>&1; then git restore --source=HEAD --staged --worktree -- 'content/posts/local.md'; else git restore --staged -- 'content/posts/local.md' >/dev/null 2>&1 || true; git clean -fd -- 'content/posts/local.md'; fi"
    ])
  }

  func testGitLabCommitRollbackDraftBuildsMergeRequestURL() throws {
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "GitLab 线上提交",
      summary: "GitLab · main · 1 个文件",
      draftTitle: "可回滚文章",
      changedPaths: ["content/posts/post.md"],
      repositoryProvider: .gitlab,
      repositoryBaseURL: "https://gitlab.com/api/v4",
      repoOwner: "group/subgroup",
      repoName: "site",
      branchName: "main",
      commitSHA: "1234567890abcdef"
    )

    let rollback = try XCTUnwrap(ReleaseLedgerService().rollbackDraft(for: record))

    XCTAssertEqual(rollback.remoteURL, "https://gitlab.com/group/subgroup/site/-/commit/1234567890abcdef")
    XCTAssertTrue(rollback.reviewURL?.hasPrefix("https://gitlab.com/group/subgroup/site/-/merge_requests/new?") == true)
    XCTAssertTrue(rollback.reviewURL?.contains("merge_request%5Bsource_branch%5D=rollback/12345678") == true)
    XCTAssertTrue(rollback.reviewURL?.contains("merge_request%5Btarget_branch%5D=main") == true)
    XCTAssertEqual(
      URLComponents(string: try XCTUnwrap(rollback.reviewURL))?.queryItems?.first { $0.name == "merge_request[title]" }?.value,
      rollback.reviewTitle
    )
  }

  func testRemotePublishFailureWithCommitBuildsRollbackPlan() throws {
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上直接提交失败",
      summary: "1 个文件已写入 main，后续请求失败。",
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abc123def4567890"
    )

    let rollback = try XCTUnwrap(ReleaseLedgerService().rollbackDraft(for: record))

    XCTAssertEqual(rollback.title, CoreL10n.format("回滚提交：%@", "部分成功文章"))
    XCTAssertTrue(rollback.commandLines.contains("git revert --no-edit 'abc123def4567890'"))
    XCTAssertTrue(rollback.commandLines.contains("git checkout -b 'rollback/abc123de'"))
    XCTAssertTrue(rollback.commandLines.contains("git push origin 'rollback/abc123de'"))
    XCTAssertEqual(rollback.changedPaths, ["content/posts/partial.md"])
    XCTAssertEqual(rollback.remoteURL, "https://github.com/owner/site/commit/abc123def4567890")
  }

  func testRemotePublishFailureOnReviewBranchBuildsBranchWithdrawalPlan() throws {
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上 PR/MR 失败",
      summary: "Review 分支已有 commit，但 MR 创建失败。",
      draftTitle: "Review 部分成功文章",
      changedPaths: ["content/posts/review-partial.md"],
      repositoryProvider: .gitlab,
      repositoryBaseURL: "https://gitlab.com/api/v4",
      repoOwner: "group/subgroup",
      repoName: "site",
      branchName: "publish/review-partial-20260829",
      targetBranch: "main",
      commitSHA: "1234567890abcdef"
    )

    let rollback = try XCTUnwrap(ReleaseLedgerService().rollbackDraft(for: record))

    XCTAssertEqual(rollback.title, CoreL10n.format("撤回发布分支：%@", "Review 部分成功文章"))
    XCTAssertEqual(rollback.commandLines, ["git push origin --delete 'publish/review-partial-20260829'"])
    XCTAssertEqual(rollback.reviewBranchName, "publish/review-partial-20260829")
    XCTAssertEqual(rollback.changedPaths, ["content/posts/review-partial.md"])
    XCTAssertEqual(
      rollback.remoteURL,
      "https://gitlab.com/group/subgroup/site/-/tree/publish/review-partial-20260829"
    )
    XCTAssertTrue(rollback.reviewBody?.contains("Review 分支已有 commit，但 MR 创建失败。") == true)
  }

  func testReleaseRecordDecodesLegacyRecordsWithoutRepositoryContext() throws {
    let data = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "kind": "remoteDirectCommit",
      "title": "线上提交",
      "summary": "GitHub · main · 1 个文件",
      "changedPaths": ["content/posts/post.md"],
      "branchName": "main",
      "commitSHA": "abcdef1234567890",
      "createdAt": "2026-07-06T00:00:00Z"
    }
    """.data(using: .utf8)!

    let record = try JSONDecoder.workbench.decode(ReleaseRecord.self, from: data)

    XCTAssertNil(record.repositoryProvider)
    XCTAssertNil(record.repoOwner)
    XCTAssertEqual(record.commitSHA, "abcdef1234567890")
    XCTAssertNil(ReleaseLedgerService().rollbackDraft(for: record)?.remoteURL)
  }
}
