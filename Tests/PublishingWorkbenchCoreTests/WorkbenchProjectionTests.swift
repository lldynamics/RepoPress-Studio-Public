import XCTest
@testable import PublishingWorkbenchCore

final class WorkbenchProjectionTests: XCTestCase {
  func testDraftListProjectionScopesAndSelectsWithoutStoreState() {
    let profileID = UUID()
    let otherProfileID = UUID()
    let siteDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "站点文章",
      date: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 20)
    )
    let otherSiteDraft = ArticleDraft(
      siteProfileID: otherProfileID,
      title: "其他站点文章",
      date: Date(timeIntervalSince1970: 30),
      updatedAt: Date(timeIntervalSince1970: 40)
    )
    let generalDraft = ArticleDraft(
      siteProfileID: profileID,
      scope: .general,
      title: "通用草稿",
      date: Date(timeIntervalSince1970: 50),
      updatedAt: Date(timeIntervalSince1970: 60)
    )
    let drafts = [siteDraft, otherSiteDraft, generalDraft]

    XCTAssertEqual(
      DraftListProjection.siteDrafts(drafts, for: profileID).map(\.id),
      [siteDraft.id]
    )
    XCTAssertEqual(
      DraftListProjection.writingDrafts(
        drafts,
        activeProfileID: profileID,
        scope: .general
      ).map(\.id),
      [generalDraft.id]
    )
    XCTAssertEqual(
      DraftListProjection.selectedDraft(
        drafts,
        selectedDraftID: siteDraft.id,
        activeProfileID: profileID,
        scope: .currentSite
      )?.id,
      siteDraft.id
    )

    let statistics = DraftListProjection.statistics(drafts, activeProfileID: profileID)
    XCTAssertEqual(statistics.totalCount, 3)
    XCTAssertEqual(statistics.siteDraftCount, 1)
    XCTAssertEqual(statistics.generalDraftCount, 1)
  }

  func testDraftListProjectionUsesStableSortRules() {
    let profileID = UUID()
    let older = ArticleDraft(
      siteProfileID: profileID,
      title: "B",
      date: Date(timeIntervalSince1970: 10),
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = ArticleDraft(
      siteProfileID: profileID,
      title: "A",
      date: Date(timeIntervalSince1970: 20),
      updatedAt: Date(timeIntervalSince1970: 20)
    )

    XCTAssertEqual(
      DraftListProjection.sorted(
        [older, newer],
        by: .updatedNewest
      ).map(\.id),
      [newer.id, older.id]
    )
    XCTAssertEqual(
      DraftListProjection.sorted(
        [older, newer],
        by: .titleAscending
      ).map(\.id),
      [newer.id, older.id]
    )
  }

  func testContentHealthProjectionAggregatesRiskAndStatistics() {
    let warning = PreflightIssue(
      severity: .warning,
      title: "疑似本机路径",
      message: "请确认公开内容",
      category: .publicRisk
    )
    let summary = DraftPreflightSummary(
      draftID: UUID(),
      draftTitle: "文章",
      markdownPath: "content/article.md",
      issues: [warning]
    )

    let risk = ContentHealthProjection.publicRiskSummary(from: [summary])
    let statistics = ContentHealthProjection.statistics(from: [summary])

    XCTAssertEqual(risk.warningCount, 1)
    XCTAssertEqual(ContentHealthProjection.publicRiskDraftSummaries(from: [summary]).count, 1)
    XCTAssertEqual(statistics.draftCount, 1)
    XCTAssertEqual(statistics.issueCount, 1)
    XCTAssertEqual(statistics.warningCount, 1)
    XCTAssertEqual(statistics.passingDraftCount, 0)
  }

  func testPublishingReadinessProjectionBlocksWriteAndCommitAtRepositoryBoundary() {
    let package = PublishPackage(
      draftID: UUID(),
      title: "文章",
      markdownPath: "content/article.md",
      files: [],
      commitMessage: "更新文章",
      reviewBranchName: "codex/article",
      reviewTitle: "更新文章",
      reviewChecklist: []
    )
    let preview = LocalPublishPreview(package: package, fileDiffs: [], issues: [])
    let notScanned = PreflightIssue(
      severity: .error,
      title: "仓库尚未扫描",
      message: "请先刷新仓库状态",
      field: "repository"
    )

    let readiness = PublishingReadinessProjection.makeReadiness(
      package: package,
      preview: preview,
      draftIssuesWithoutRepository: [],
      draftIssuesWithRepository: [],
      repositoryBlockingIssues: [notScanned]
    )

    XCTAssertEqual(readiness.writeReadiness, .blocked)
    XCTAssertEqual(readiness.commitReadiness, .blocked)
    XCTAssertEqual(readiness.writeBlockingIssues, [notScanned])
    XCTAssertEqual(readiness.commitBlockingIssues, [notScanned])
    XCTAssertEqual(readiness.changedFileCount, 0)
  }
}

final class WorkbenchOperationLogServiceTests: XCTestCase {
  func testProjectsEverySourceUsingSafeWhitelistedCopy() {
    let profileID = UUID()
    let draftID = UUID()
    let profile = SiteProfile(id: profileID, name: "允许显示的站点")
    let draft = ArticleDraft(siteProfileID: profileID, title: "允许显示的文章")
    let releaseID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let release = ReleaseRecord(
      id: releaseID,
      kind: .remoteDirectCommit,
      title: "RELEASE_TITLE_SECRET",
      summary: "RELEASE_SUMMARY_SECRET",
      siteProfileID: profileID,
      draftID: draftID,
      draftTitle: "允许显示的文章",
      changedPaths: ["/private/RELEASE_PATH_SECRET"],
      createdAt: timestamp
    )
    let maintenance = MaintenanceOperationRecord(
      id: UUID(),
      profileID: profileID,
      actionKind: .linkAudit,
      actionTitle: "MAINTENANCE_TITLE_SECRET",
      summary: "MAINTENANCE_SUMMARY_SECRET",
      draftID: draftID,
      targetPath: "/private/MAINTENANCE_PATH_SECRET",
      createdAt: timestamp.addingTimeInterval(1)
    )
    let automation = WorkbenchAutomationRunRecord(
      id: UUID(),
      planID: UUID(),
      goal: "AUTOMATION_GOAL_SECRET",
      startedAt: timestamp,
      completedAt: timestamp.addingTimeInterval(2),
      steps: [
        .init(
          command: .updateMetadata, status: .succeeded, message: "STEP_MESSAGE_SECRET",
          targetDraftID: draftID),
        .init(command: .saveWorkbench, status: .failed, message: "SECOND_STEP_MESSAGE_SECRET"),
      ]
    )
    let aiMetadata = AIPublishingMetadataApplicationRecord(
      id: UUID(),
      siteProfileID: profileID,
      draftID: draftID,
      draftTitle: "允许显示的文章",
      createdAt: timestamp.addingTimeInterval(3),
      fields: [.title, .summary],
      previousTitle: "AI_PREVIOUS_SECRET",
      newTitle: "AI_NEW_SECRET",
      previousSummary: "AI_PREVIOUS_SUMMARY_SECRET",
      newSummary: "AI_NEW_SUMMARY_SECRET"
    )
    let deployment = DeploymentStatusSnapshot(
      id: UUID(),
      profileID: profileID,
      releaseRecordID: releaseID,
      provider: .cloudflarePages,
      level: .success,
      title: "DEPLOYMENT_TITLE_SECRET",
      message: "DEPLOYMENT_MESSAGE_SECRET",
      siteURLText: "https://DEPLOYMENT_URL_SECRET.example",
      checkedAt: timestamp.addingTimeInterval(4),
      signals: []
    )

    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [release],
      maintenanceOperationRecords: [maintenance],
      automationRunRecords: [automation],
      aiMetadataApplicationRecords: [aiMetadata],
      deploymentStatusSnapshots: [deployment],
      profiles: [profile],
      drafts: [draft]
    )

    XCTAssertEqual(
      entries.map(\.category), [.deployment, .ai, .automation, .maintenance, .publishing])
    XCTAssertEqual(entries.first { $0.category == .publishing }?.outcome, .succeeded)
    XCTAssertEqual(entries.first { $0.category == .maintenance }?.outcome, .recorded)
    XCTAssertEqual(entries.first { $0.category == .automation }?.outcome, .partial)
    XCTAssertEqual(entries.first { $0.category == .ai }?.outcome, .succeeded)
    XCTAssertEqual(entries.first { $0.category == .deployment }?.outcome, .observed)
    XCTAssertEqual(entries.first { $0.category == .deployment }?.targetLabel, "允许显示的文章")

    let rendered = entries.map { entry in
      [entry.title, entry.summary, entry.targetLabel ?? ""].joined(separator: " ")
    }.joined(separator: "\n")
    let forbiddenSourceText = [
      "RELEASE_TITLE_SECRET", "RELEASE_SUMMARY_SECRET", "RELEASE_PATH_SECRET",
      "MAINTENANCE_TITLE_SECRET", "MAINTENANCE_SUMMARY_SECRET", "MAINTENANCE_PATH_SECRET",
      "AUTOMATION_GOAL_SECRET", "STEP_MESSAGE_SECRET", "SECOND_STEP_MESSAGE_SECRET",
      "AI_PREVIOUS_SECRET", "AI_NEW_SECRET", "AI_PREVIOUS_SUMMARY_SECRET", "AI_NEW_SUMMARY_SECRET",
      "DEPLOYMENT_TITLE_SECRET", "DEPLOYMENT_MESSAGE_SECRET", "DEPLOYMENT_URL_SECRET",
    ]
    for sourceText in forbiddenSourceText {
      XCTAssertFalse(rendered.contains(sourceText), "Unexpected source text: \(sourceText)")
    }
  }

  func testAutomationOutcomeAccountsForPendingConfirmationSteps() {
    let date = Date(timeIntervalSince1970: 2_000)
    let records: [(WorkbenchOperationLogOutcome, [WorkbenchAutomationStepStatus])] = [
      (.succeeded, [.succeeded, .succeeded]),
      (.partial, [.succeeded, .failed]),
      (.failed, [.failed, .failed]),
      (.cancelled, [.cancelled]),
      (.recorded, [.running, .awaitingConfirmation]),
      (.partial, [.succeeded, .awaitingConfirmation]),
      (.partial, [.succeeded, .running]),
    ]

    let runs = records.enumerated().map { index, item in
      WorkbenchAutomationRunRecord(
        id: deterministicUUID(index),
        planID: UUID(),
        goal: "untrusted",
        startedAt: date,
        completedAt: date.addingTimeInterval(TimeInterval(index)),
        steps: item.1.map { .init(command: .saveWorkbench, status: $0, message: "untrusted") }
      )
    }
    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [],
      maintenanceOperationRecords: [],
      automationRunRecords: runs,
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      profiles: [],
      drafts: []
    )

    for (expected, run) in zip(records.map(\.0), runs) {
      XCTAssertEqual(entries.first { $0.sourceReference.id == run.id }?.outcome, expected)
    }
    XCTAssertEqual(
      entries.first { $0.sourceReference.id == runs[5].id }?.summary,
      CoreL10n.format(
        "自动化步骤：%lld 成功，%lld 失败，%lld 已取消，%lld 待处理",
        Int64(1),
        Int64(0),
        Int64(0),
        Int64(1)
      )
    )
  }

  func testRemotePublishFailureUsesCommitSHAAsTheRecoveryBoundary() {
    let date = Date(timeIntervalSince1970: 2_500)
    let partial = ReleaseRecord(
      id: deterministicUUID(21),
      kind: .remotePublishFailure,
      title: "untrusted",
      summary: "untrusted",
      changedPaths: ["content/partial.md"],
      commitSHA: "abc123",
      createdAt: date
    )
    let failed = ReleaseRecord(
      id: deterministicUUID(22),
      kind: .remotePublishFailure,
      title: "untrusted",
      summary: "untrusted",
      changedPaths: ["content/planned-but-not-written.md"],
      createdAt: date.addingTimeInterval(1)
    )
    let blankCommit = ReleaseRecord(
      id: deterministicUUID(23),
      kind: .remotePublishFailure,
      title: "untrusted",
      summary: "untrusted",
      changedPaths: ["content/blank.md"],
      commitSHA: "   ",
      createdAt: date.addingTimeInterval(2)
    )

    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [partial, failed, blankCommit],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      profiles: [],
      drafts: []
    )

    XCTAssertEqual(
      entries.first { $0.sourceReference.id == partial.id }?.outcome,
      .partial
    )
    XCTAssertEqual(
      entries.first { $0.sourceReference.id == failed.id }?.outcome,
      .failed
    )
    XCTAssertEqual(
      entries.first { $0.sourceReference.id == blankCommit.id }?.outcome,
      .failed
    )
    XCTAssertEqual(
      entries.first { $0.sourceReference.id == partial.id }?.summary,
      CoreL10n.text("远端发布部分完成后中断；需要确认远端 commit、Review 或回滚方案。")
    )
  }

  func testDeploymentIncludesOnlySuccessAndFailureSnapshots() {
    let profileID = UUID()
    let date = Date(timeIntervalSince1970: 3_000)
    let snapshots = DeploymentStatusLevel.allCases.map { level in
      DeploymentStatusSnapshot(
        id: UUID(),
        profileID: profileID,
        releaseRecordID: nil,
        provider: .vercel,
        level: level,
        title: "untrusted",
        message: "untrusted",
        siteURLText: "https://example.com",
        checkedAt: date,
        signals: []
      )
    }
    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: snapshots,
      profiles: [],
      drafts: []
    )

    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(Set(entries.map(\.outcome)), [.observed, .failed])
  }

  func testUsesStableSourceScopedIDsSortsDeterministicallyAndLimitsToFiveHundred() {
    let date = Date(timeIntervalSince1970: 4_000)
    let sharedID = deterministicUUID(9_999)
    let collisionEntries = WorkbenchOperationLogService().entries(
      releaseRecords: [
        ReleaseRecord(id: sharedID, title: "untrusted", summary: "untrusted", createdAt: date)
      ],
      maintenanceOperationRecords: [
        MaintenanceOperationRecord(
          id: sharedID,
          profileID: UUID(),
          actionKind: .taxonomy,
          actionTitle: "untrusted",
          summary: "untrusted",
          createdAt: date
        )
      ],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      profiles: [],
      drafts: []
    )
    XCTAssertEqual(Set(collisionEntries.map(\.id)).count, 2)
    XCTAssertTrue(
      collisionEntries.contains { $0.id == "releaseRecord:\(sharedID.uuidString.lowercased())" })
    XCTAssertTrue(
      collisionEntries.contains {
        $0.id == "maintenanceOperation:\(sharedID.uuidString.lowercased())"
      })

    let releaseRecords = (0...500).reversed().map { index in
      ReleaseRecord(
        id: deterministicUUID(index),
        title: "untrusted",
        summary: "untrusted",
        createdAt: date
      )
    }
    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: releaseRecords,
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      profiles: [],
      drafts: []
    )

    XCTAssertEqual(entries.count, WorkbenchOperationLogService.maximumEntryCount)
    XCTAssertEqual(entries.map(\.id), entries.map(\.id).sorted())
    XCTAssertEqual(
      entries.first?.id, "releaseRecord:\(deterministicUUID(0).uuidString.lowercased())")
    XCTAssertEqual(
      entries.last?.id, "releaseRecord:\(deterministicUUID(499).uuidString.lowercased())")
  }

  func testDuplicateSourceIDsKeepOnlyTheNewestProjection() {
    let sharedID = deterministicUUID(42)
    let older = ReleaseRecord(
      id: sharedID,
      kind: .localWrite,
      title: "untrusted",
      summary: "untrusted",
      changedPaths: ["one"],
      createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let newer = ReleaseRecord(
      id: sharedID,
      kind: .directCommit,
      title: "untrusted",
      summary: "untrusted",
      changedPaths: ["one", "two"],
      createdAt: Date(timeIntervalSince1970: 2_000)
    )

    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [older, newer],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      profiles: [],
      drafts: []
    )

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.occurredAt, newer.createdAt)
    XCTAssertTrue(entries.first?.summary.contains("2") == true)
  }

  private func deterministicUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}

final class WorkbenchOperationLedgerTests: XCTestCase {
  func testFailedNativeEventSummaryDoesNotInventZeroCounts() {
    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      operationEvents: [
        WorkbenchOperationEventRecord(
          kind: .knowledgeImport,
          outcome: .failed
        )
      ],
      profiles: [],
      drafts: []
    )

    XCTAssertTrue(
      entries.first?.summary.contains(WorkbenchOperationLogOutcome.failed.displayName) == true
    )
    XCTAssertFalse(entries.first?.summary.contains("新增 0") == true)
  }

  func testNativeEventProjectionUsesSafeSemanticFieldsAndUnifiedCutoff() {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "可显示文章"
    )
    let cutoff = Date(timeIntervalSince1970: 2_000)
    let oldRelease = ReleaseRecord(
      title: "UNTRUSTED_RELEASE_TITLE",
      summary: "UNTRUSTED_RELEASE_SUMMARY",
      siteProfileID: profileID,
      draftID: draft.id,
      changedPaths: ["/private/UNTRUSTED_PATH"],
      createdAt: cutoff.addingTimeInterval(-1)
    )
    let event = WorkbenchOperationEventRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
      kind: .imageWebPConversion,
      outcome: .succeeded,
      profileID: profileID,
      draftID: draft.id,
      occurredAt: cutoff.addingTimeInterval(1),
      processedItemCount: 3,
      skippedItemCount: 1,
      savedByteCount: 4_096
    )

    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [oldRelease],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      operationEvents: [event],
      visibleSince: cutoff,
      profiles: [SiteProfile(id: profileID, name: "可显示站点")],
      drafts: [draft]
    )

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.sourceReference.kind, .operationEvent)
    XCTAssertEqual(entries.first?.category, .images)
    XCTAssertEqual(entries.first?.targetLabel, "可显示文章")
    XCTAssertTrue(entries.first?.summary.contains("3") == true)
    XCTAssertFalse(entries.map(\.summary).joined().contains("UNTRUSTED"))
  }

  func testLedgerRetentionAndLastKnownGoodRecovery() throws {
    let directory = try makeTemporaryDirectory(prefix: "operation-ledger-recovery")
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: directory.appendingPathComponent("workbench.operation-log.json")
    )
    let now = Date(timeIntervalSince1970: 20_000_000)
    let retained = WorkbenchOperationEventRecord(
      kind: .knowledgeImport,
      outcome: .succeeded,
      occurredAt: now.addingTimeInterval(-10),
      createdItemCount: 2
    )
    let expired = WorkbenchOperationEventRecord(
      kind: .knowledgeImport,
      outcome: .succeeded,
      occurredAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
      createdItemCount: 99
    )
    let firstDocument = WorkbenchOperationLedgerDocument(
      retentionPolicy: .thirtyDays,
      records: [retained, expired]
    )
    try persistence.save(firstDocument, now: now)

    let newer = WorkbenchOperationEventRecord(
      kind: .workspaceBackupCreated,
      outcome: .succeeded,
      occurredAt: now,
      draftCount: 4
    )
    try persistence.save(
      WorkbenchOperationLedgerDocument(
        retentionPolicy: .thirtyDays,
        records: [newer, retained]
      ),
      now: now
    )
    try Data("not-json".utf8).write(to: persistence.fileURL, options: [.atomic])

    let recovered = try persistence.loadWithRecovery(now: now)
    XCTAssertNotNil(recovered.recoveryMessage)
    XCTAssertEqual(recovered.document.records.map(\.id), [retained.id])
    XCTAssertFalse(recovered.document.records.contains { $0.id == expired.id })
  }

  @MainActor
  func testClearUsesWatermarkWithoutDeletingCanonicalSourceRecords() throws {
    let directory = try makeTemporaryDirectory(prefix: "operation-ledger-clear")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clearDate = Date(timeIntervalSince1970: 40_000)
    let history = WorkbenchOperationHistoryStore(
      persistence: WorkbenchOperationLedgerPersistence(
        fileURL: directory.appendingPathComponent("workbench.operation-log.json")
      ),
      now: { clearDate }
    )
    let event = WorkbenchOperationEventRecord(
      kind: .localContentImport,
      outcome: .succeeded,
      occurredAt: clearDate.addingTimeInterval(-1),
      createdItemCount: 1
    )
    XCTAssertTrue(history.record(event))
    XCTAssertTrue(history.clearHistory())
    XCTAssertEqual(history.visibleSince, clearDate)
    XCTAssertTrue(history.records.isEmpty)

    let canonicalRelease = ReleaseRecord(
      title: "canonical",
      summary: "canonical",
      createdAt: clearDate.addingTimeInterval(-1)
    )
    let entries = WorkbenchOperationLogService().entries(
      releaseRecords: [canonicalRelease],
      maintenanceOperationRecords: [],
      automationRunRecords: [],
      aiMetadataApplicationRecords: [],
      deploymentStatusSnapshots: [],
      operationEvents: history.records,
      visibleSince: history.visibleCutoff(relativeTo: clearDate),
      profiles: [],
      drafts: []
    )
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(canonicalRelease.title, "canonical")
  }

  @MainActor
  func testUnrecoverableLedgerIsQuarantinedWithoutBlockingNewWrites() async throws {
    let directory = try makeTemporaryDirectory(prefix: "operation-ledger-quarantine")
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: directory.appendingPathComponent("workbench.operation-log.json")
    )
    try Data("broken-primary".utf8).write(to: persistence.fileURL, options: [.atomic])
    try Data("broken-backup".utf8).write(
      to: persistence.lastKnownGoodURL,
      options: [.atomic]
    )

    let now = Date(timeIntervalSince1970: 50_000)
    let history = WorkbenchOperationHistoryStore(
      persistence: persistence,
      now: { now }
    )
    let recoveredDocument = await history.flush()
    XCTAssertNotNil(recoveredDocument)
    XCTAssertNotNil(history.lastErrorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.fileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.lastKnownGoodURL.path))
    XCTAssertTrue(
      history.record(
        WorkbenchOperationEventRecord(
          kind: .workspaceBackupCreated,
          outcome: .succeeded,
          occurredAt: now,
          draftCount: 1
        )
      )
    )
    XCTAssertEqual(history.records.count, 1)
    let savedDocument = await history.flush()
    XCTAssertNotNil(savedDocument)
    XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.fileURL.path))
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

private actor AcceptedKnowledgeMutationProjectionGate {
  private var didArrive = false
  private var arrivalWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func arriveAndWaitForRelease() async {
    didArrive = true
    arrivalWaiter?.resume()
    arrivalWaiter = nil
    await withCheckedContinuation { continuation in
      releaseWaiter = continuation
    }
  }

  func waitUntilArrived() async {
    guard !didArrive else { return }
    await withCheckedContinuation { continuation in
      arrivalWaiter = continuation
    }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

@MainActor
final class KnowledgeStoreConcurrencyTests: XCTestCase {
  func testBusyOperationLeasesRemainBusyUntilEveryLeaseFinishes() async {
    let rootURL = temporaryDirectory(named: "knowledge-store-busy-leases")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = KnowledgeStore(service: KnowledgeLibraryService(rootURL: rootURL))
    await store.reload()

    let first = store.beginBusyOperation()
    let second = store.beginBusyOperation()
    XCTAssertTrue(store.isBusy)

    store.finishBusyOperation(first)
    XCTAssertTrue(store.isBusy)

    store.finishBusyOperation(second)
    XCTAssertFalse(store.isBusy)
  }

  func testBackupSerializesAgainstConcurrentImportAndDelete() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-mutation-barrier")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let firstSourceURL = rootURL.appendingPathComponent("first.md")
    let secondSourceURL = rootURL.appendingPathComponent("second.md")
    try "# First\n\nExisting document.".write(to: firstSourceURL, atomically: true, encoding: .utf8)
    try "# Second\n\nConcurrent import document.".write(
      to: secondSourceURL,
      atomically: true,
      encoding: .utf8
    )

    let service = KnowledgeLibraryService(rootURL: storeURL)
    let initialImport = try await service.commit(
      try await service.makeImportPreview(sourceURL: firstSourceURL)
    )
    let initialDocumentID = try XCTUnwrap(initialImport.documentIDs.first)
    let concurrentPreview = try await service.makeImportPreview(sourceURL: secondSourceURL)
    let backupURL = rootURL.appendingPathComponent("race.pslibrarybackup", isDirectory: true)

    async let backup = service.createBackup(at: backupURL, applicationVersion: "test")
    async let imported = service.commit(concurrentPreview)
    async let deleted: KnowledgeDocumentDeletionReport = Task.detached(priority: .userInitiated) {
      try service.deleteDocument(id: initialDocumentID)
    }.value

    let backupPreview = try await backup
    let importedResult = try await imported
    _ = try await deleted
    let inspectedPreview = try await service.inspectBackup(at: backupURL)

    XCTAssertEqual(backupPreview, inspectedPreview)
    XCTAssertTrue((0...2).contains(backupPreview.documentCount))
    XCTAssertEqual(importedResult.insertedCount, 1)
    XCTAssertEqual(try service.documents().count, 1)
  }

  func testQueuedStoreMutationDoesNotBlockMainActorAndReconcilesConcurrentDelete() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-store-queued-mutations")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Source\n\nThis document is deleted while its recycle request is pending."
      .write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let imported = try await service.commit(
      try await service.makeImportPreview(sourceURL: sourceURL)
    )
    let documentID = try XCTUnwrap(imported.documentIDs.first)
    let store = KnowledgeStore(service: service)
    await store.reload()

    // The write awaits persistence, but it suspends rather than blocking the
    // main actor while SQLite/file work is pending.
    let recycleTask = Task { @MainActor in
      await store.moveToRecycleBin([documentID])
    }
    var mainActorAdvanced = false
    Task { @MainActor in mainActorAdvanced = true }
    await Task.yield()
    XCTAssertTrue(mainActorAdvanced)

    let recycled = await recycleTask.value
    XCTAssertTrue(recycled)
    let deleted = await store.deleteDocument(documentID)
    XCTAssertTrue(deleted)
    await waitForQueuedStoreOperations(store)
    await store.reload()
    XCTAssertFalse(store.documents.contains { $0.id == documentID })
    XCTAssertFalse(store.recycledDocuments.contains { $0.id == documentID })
  }

  func testMissingDocumentDeleteReportsFailureAndFIFOPinnedWritesConverge() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-store-fifo-pinned")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Source\n\nPinned state test.".write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let imported = try await service.commit(
      try await service.makeImportPreview(sourceURL: sourceURL))
    let documentID = try XCTUnwrap(imported.documentIDs.first)
    let store = KnowledgeStore(service: service)
    await store.reload()

    let missingDeleteSucceeded = await store.deleteDocument(UUID())
    XCTAssertFalse(missingDeleteSucceeded)

    let setPinned = Task { @MainActor in await store.setPinned(true, documentID: documentID) }
    await Task.yield()
    let clearPinned = Task { @MainActor in await store.setPinned(false, documentID: documentID) }
    await setPinned.value
    await clearPinned.value

    XCTAssertFalse(store.isPinned(documentID))
    XCTAssertFalse(try service.pinnedDocumentIDs().contains(documentID))
  }

  func testAcceptedCommitReprojectsAfterInitiatingTaskIsCancelled() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-store-cancelled-commit-projection")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# Durable\n\nThe accepted import must remain visible after cancellation."
      .write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    let store = KnowledgeStore(service: service)
    await store.reload()
    let projectionGate = AcceptedKnowledgeMutationProjectionGate()
    store.afterAcceptedMutationBeforeProjection = {
      await projectionGate.arriveAndWaitForRelease()
    }
    defer { store.afterAcceptedMutationBeforeProjection = nil }

    let importTask = Task { @MainActor in
      try await store.commit(preview)
    }
    await projectionGate.waitUntilArrived()
    XCTAssertEqual(try service.documents().count, 1)
    XCTAssertTrue(store.documents.isEmpty)
    importTask.cancel()
    await projectionGate.release()

    let result = try await importTask.value
    let importedID = try XCTUnwrap(result.documentIDs.first)
    XCTAssertEqual(try service.documents().map(\.id), [importedID])
    XCTAssertEqual(store.documents.map(\.id), [importedID])
    XCTAssertEqual(store.selectedDocumentID, importedID)
    XCTAssertNil(store.lastError)
  }

  private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "KnowledgeStoreConcurrencyTests-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
  }

  private func waitForQueuedStoreOperations(
    _ store: KnowledgeStore,
    timeout: TimeInterval = 2
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while store.isBusy, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(store.isBusy, "Queued knowledge operation did not finish before timeout.")
  }

}

final class WorkbenchOperationLedgerAsyncPersistenceTests: XCTestCase {
  @MainActor
  func testInitialLedgerLoadRunsOutsideMainActor() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "OperationLedgerLoad")
    defer { try? FileManager.default.removeItem(at: directory) }

    let threadRecorder = LedgerThreadRecorder()
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: directory.appendingPathComponent("operation-log.json"),
      hooks: .init(beforeLoad: {
        threadRecorder.record(Thread.isMainThread)
        Thread.sleep(forTimeInterval: 0.20)
      })
    )
    let startedAt = Date()
    let history = WorkbenchOperationHistoryStore(persistence: persistence)

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.10)
    let flushedDocument = await history.flush()
    XCTAssertNotNil(flushedDocument)
    XCTAssertEqual(threadRecorder.values, [false])
  }

  @MainActor
  func testRecordQueuesSlowDiskWriteWithoutBlockingMainActor() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "OperationLedgerAsync")
    defer { try? FileManager.default.removeItem(at: directory) }

    let threadRecorder = LedgerThreadRecorder()
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: directory.appendingPathComponent("operation-log.json"),
      hooks: .init(beforeSave: {
        threadRecorder.record(Thread.isMainThread)
        Thread.sleep(forTimeInterval: 0.20)
      })
    )
    let history = WorkbenchOperationHistoryStore(persistence: persistence)
    let startedAt = Date()

    XCTAssertTrue(history.record(makeRecord(kind: .localContentImport)))
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.10)
    XCTAssertEqual(history.records.count, 1)

    let flushedDocument = await history.flush()
    XCTAssertNotNil(flushedDocument)
    XCTAssertEqual(threadRecorder.values, [false])
  }

  @MainActor
  func testQueuedWritesPreserveLatestLedgerAndFlushProvidesDurableSnapshot() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "OperationLedgerOrder")
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: directory.appendingPathComponent("operation-log.json")
    )
    let history = WorkbenchOperationHistoryStore(
      persistence: persistence,
      now: { Date(timeIntervalSince1970: 10_000) }
    )
    let first = makeRecord(
      kind: .siteImport,
      occurredAt: Date(timeIntervalSince1970: 10_001)
    )
    let second = makeRecord(
      kind: .workspaceBackupCreated,
      occurredAt: Date(timeIntervalSince1970: 10_002)
    )

    XCTAssertTrue(history.record(first))
    XCTAssertTrue(history.record(second))
    let flushedDocument = await history.flush()
    let frozenDocument = try XCTUnwrap(flushedDocument)

    XCTAssertEqual(frozenDocument.records.map(\.id), [second.id, first.id])
    let ledgerNow = Date(timeIntervalSince1970: 10_000)
    XCTAssertEqual(try persistence.loadWithRecovery(now: ledgerNow).document, frozenDocument)
    let priorDurableDocument = try WorkbenchOperationLedgerPersistence.decodedDocument(
      from: Data(contentsOf: persistence.lastKnownGoodURL),
      now: ledgerNow
    )
    XCTAssertEqual(priorDurableDocument.records.map(\.id), [first.id])
  }

  @MainActor
  func testFlushPublishesQueuedWriteFailureAfterMemoryAcceptance() async throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "OperationLedgerFailure")
    defer { try? FileManager.default.removeItem(at: directory) }
    let blockingParent = directory.appendingPathComponent("not-a-directory")
    try Data("file".utf8).write(to: blockingParent)
    let persistence = WorkbenchOperationLedgerPersistence(
      fileURL: blockingParent.appendingPathComponent("operation-log.json")
    )
    let history = WorkbenchOperationHistoryStore(persistence: persistence)

    XCTAssertTrue(history.record(makeRecord(kind: .knowledgeImport)))
    XCTAssertEqual(history.records.count, 1)
    let flushedDocument = await history.flush()
    XCTAssertNil(flushedDocument)
    XCTAssertTrue(history.lastErrorMessage?.contains("活动记录保存失败") ?? false)
  }

  private func makeRecord(
    kind: WorkbenchOperationEventKind,
    occurredAt: Date = Date()
  ) -> WorkbenchOperationEventRecord {
    WorkbenchOperationEventRecord(
      kind: kind,
      outcome: .succeeded,
      occurredAt: occurredAt
    )
  }
}

private final class LedgerThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [Bool] = []

  func record(_ value: Bool) {
    lock.lock()
    storedValues.append(value)
    lock.unlock()
  }

  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storedValues
  }
}

final class WorkbenchOperationLogAsyncStoreTests: XCTestCase {
  @MainActor
  func testStoreRecordBooleanMeansMemoryProjectionAndFlushAcknowledgesDurability() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "OperationLogStoreFlush")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(
      persistence: persistence,
      knowledgeLibraryService: KnowledgeLibraryService(
        rootURL: rootURL.appendingPathComponent("KnowledgeLibrary")
      )
    )
    let record = WorkbenchOperationEventRecord(
      kind: .imageResize,
      outcome: .succeeded,
      occurredAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
      processedItemCount: 1
    )

    XCTAssertTrue(store.recordOperationEvent(record))
    XCTAssertEqual(store.operationHistory.records.map(\.id), [record.id])
    let flushedDocument = await store.flushOperationLogPersistence()
    let document = try XCTUnwrap(flushedDocument)

    XCTAssertEqual(document.records.map(\.id), [record.id])
    let saved = try WorkbenchOperationLedgerPersistence(
      fileURL: persistence.operationLedgerURL
    ).loadWithRecovery().document
    XCTAssertEqual(saved, document)
  }
}
