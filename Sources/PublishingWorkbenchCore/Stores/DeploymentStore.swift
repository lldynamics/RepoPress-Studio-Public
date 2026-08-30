import Combine
import Foundation

@MainActor
public final class DeploymentStore: ObservableObject {
  private static let deploymentStatusHistoryLimitPerRecord = 6
  private static let reviewStatusPollingLimitPerProfile = 20
  private static let reviewFailureSummaryLimit = 20

  private let deploymentStatusService: DeploymentStatusService
  private let deploymentTokenStore: KeychainTokenStore
  private let remoteRepositoryPublishService: RemoteRepositoryPublishService
  private let repositoryTokenStore: KeychainTokenStore
  private let releaseLedgerService: ReleaseLedgerService
  private var latestDeploymentStatusRequestIDByRecord: [UUID: UUID] = [:]
  private var latestReviewStatusRequestIDByRecord: [UUID: UUID] = [:]
  private var activeDeploymentStatusRequestIDsByProfileID: [UUID: Set<UUID>] = [:]
  private var activeReviewStatusRequestIDsByProfileID: [UUID: Set<UUID>] = [:]
  private var deploymentPollingGenerationByProfileID: [UUID: UInt64] = [:]
  private var activeDeploymentPollingProfileIDs: Set<UUID> = []
  private var reviewPollingCursorByProfileID: [UUID: Int] = [:]
  private var deploymentStatusMessageByProfileID: [UUID: String] = [:]

  @Published public internal(set) var deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot]
  @Published public internal(set) var deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]]
  @Published public internal(set) var isDeploymentStatusChecking: Bool
  @Published public internal(set) var deploymentStatusMessage: String?
  @Published public internal(set) var deploymentPollingSettings: DeploymentPollingSettings {
    didSet {
      guard let profileID = boundAutomationProfileID else { return }
      deploymentPollingSettingsByProfileID[profileID] = deploymentPollingSettings
    }
  }
  @Published public internal(set) var deploymentPollingState: DeploymentPollingState {
    didSet {
      guard let profileID = boundAutomationProfileID else { return }
      deploymentPollingStateByProfileID[profileID] = deploymentPollingState
    }
  }
  @Published public internal(set) var deploymentPollingSettingsByProfileID:
    [UUID: DeploymentPollingSettings]
  @Published public internal(set) var deploymentPollingStateByProfileID:
    [UUID: DeploymentPollingState]
  @Published public internal(set) var deploymentTokenAvailability: KeychainTokenAvailability
  private var boundAutomationProfileID: UUID?

  init(
    deploymentStatusSnapshots: [UUID: DeploymentStatusSnapshot] = [:],
    deploymentStatusHistory: [UUID: [DeploymentStatusSnapshot]] = [:],
    isDeploymentStatusChecking: Bool = false,
    deploymentStatusMessage: String? = nil,
    deploymentPollingSettings: DeploymentPollingSettings = .default,
    deploymentPollingState: DeploymentPollingState = .idle,
    deploymentPollingSettingsByProfileID: [UUID: DeploymentPollingSettings] = [:],
    deploymentPollingStateByProfileID: [UUID: DeploymentPollingState] = [:],
    activeProfileID: UUID? = nil,
    deploymentTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(
      hasToken: false),
    deploymentStatusService: DeploymentStatusService = DeploymentStatusService(),
    deploymentTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.deployment, accountPrefix: "deployment-provider"),
    remoteRepositoryPublishService: RemoteRepositoryPublishService =
      RemoteRepositoryPublishService(),
    repositoryTokenStore: KeychainTokenStore = KeychainTokenStore(
      service: KeychainCredentialServices.repository, accountPrefix: "repository-provider"),
    releaseLedgerService: ReleaseLedgerService = ReleaseLedgerService()
  ) {
    self.deploymentStatusService = deploymentStatusService
    self.deploymentTokenStore = deploymentTokenStore
    self.remoteRepositoryPublishService = remoteRepositoryPublishService
    self.repositoryTokenStore = repositoryTokenStore
    self.releaseLedgerService = releaseLedgerService
    self.deploymentStatusSnapshots = deploymentStatusSnapshots
    self.deploymentStatusHistory = deploymentStatusHistory
    self.isDeploymentStatusChecking = isDeploymentStatusChecking
    self.deploymentStatusMessage = deploymentStatusMessage
    self.deploymentPollingSettingsByProfileID = deploymentPollingSettingsByProfileID
    self.deploymentPollingStateByProfileID = deploymentPollingStateByProfileID
    self.deploymentPollingSettings =
      activeProfileID.flatMap {
        deploymentPollingSettingsByProfileID[$0]
      } ?? deploymentPollingSettings
    self.deploymentPollingState =
      activeProfileID.flatMap {
        deploymentPollingStateByProfileID[$0]
      } ?? deploymentPollingState
    self.deploymentTokenAvailability = deploymentTokenAvailability
    self.boundAutomationProfileID = activeProfileID
  }

  public func deploymentStatusReadiness(
    for profile: SiteProfile,
    hasToken: Bool
  ) -> DeploymentStatusProviderReadiness {
    deploymentStatusService.readiness(
      profile: profile,
      hasToken: hasToken
    )
  }

  public func deploymentStatusReadiness(
    for profile: SiteProfile,
    tokenAvailability: KeychainTokenAvailability
  ) -> DeploymentStatusProviderReadiness {
    var readiness = deploymentStatusReadiness(
      for: profile,
      hasToken: tokenAvailability.hasToken
    )
    guard let accessFailureMessage = tokenAvailability.accessFailureMessage else {
      return readiness
    }

    let accessFailureRequirement = CoreL10n.format(
      "部署 Token 状态读取失败：%@",
      accessFailureMessage
    )
    readiness.missingRequirements.removeAll {
      $0 == CoreL10n.text("部署 Token")
    }
    readiness.missingRequirements.insert(accessFailureRequirement, at: 0)
    if readiness.canCheckAnyStatus {
      readiness.nextStep = accessFailureRequirement
    } else {
      readiness.nextStep = CoreL10n.format(
        "先补齐 %@。",
        readiness.missingRequirements.joined(separator: CoreL10n.text("、"))
      )
      readiness.fallbackMessage = [
        readiness.fallbackMessage,
        accessFailureRequirement,
      ].joined(separator: " ")
    }
    return readiness
  }

  public func deploymentStatusReadiness(
    for record: ReleaseRecord,
    store: WorkbenchStore
  ) -> DeploymentStatusProviderReadiness {
    deploymentStatusReadiness(
      for: store.profile(for: record),
      tokenAvailability: resolvedDeploymentTokenAvailability(
        for: store.profile(for: record)
      )
    )
  }

  public func activeDeploymentStatusReadiness(store: WorkbenchStore)
    -> DeploymentStatusProviderReadiness
  {
    deploymentStatusReadiness(
      for: store.activeProfile,
      tokenAvailability: deploymentTokenAvailability
    )
  }

  public func shouldRefreshDeploymentStatusAfterRemoteOperation(
    _ record: ReleaseRecord,
    store: WorkbenchStore
  ) -> Bool {
    guard releaseCanHaveDeployment(record) else { return false }
    return deploymentStatusReadiness(for: record, store: store).canCheckAnyStatus
  }

  public func deploymentStatusSnapshot(for record: ReleaseRecord) -> DeploymentStatusSnapshot? {
    deploymentStatusSnapshots[record.id]
  }

  public func deploymentStatusHistory(for record: ReleaseRecord, limit: Int = 6)
    -> [DeploymentStatusSnapshot]
  {
    Array((deploymentStatusHistory[record.id] ?? []).prefix(max(limit, 0)))
  }

  public func remoteRollbackDraft(for record: ReleaseRecord) -> RemoteRepositoryRollbackDraft? {
    try? RemoteRepositoryRollbackDraft.make(record: record)
  }

  public func remoteReviewWithdrawalDraft(for record: ReleaseRecord)
    -> RemoteRepositoryReviewWithdrawalDraft?
  {
    guard record.reviewStatus?.state.isTerminal != true else { return nil }
    return try? RemoteRepositoryReviewWithdrawalDraft.make(record: record)
  }

  public func reviewPollingEligibleRecords(
    for profileID: UUID,
    store: WorkbenchStore,
    includeLegacyRecords: Bool = false
  ) -> [ReleaseRecord] {
    let allowLegacyRecords = includeLegacyRecords && profileID == store.activeProfileID
    let records = store.releaseRecords.filter { record in
      guard record.kind == .remoteReviewRequest,
        record.reviewStatus?.state != .merged,
        record.reviewURL?.trimmedForPublishing.nilIfEmpty != nil,
        record.branchName?.trimmedForPublishing.nilIfEmpty != nil,
        record.targetBranch?.trimmedForPublishing.nilIfEmpty != nil,
        record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil,
        record.siteProfileID == profileID || (allowLegacyRecords && record.siteProfileID == nil)
      else {
        return false
      }
      return true
    }
    .sorted { lhs, rhs in
      lhs.createdAt == rhs.createdAt
        ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt
    }
    guard records.count > Self.reviewStatusPollingLimitPerProfile else { return records }
    let cursor = reviewPollingCursorByProfileID[profileID, default: 0] % records.count
    let rotated = Array(records[cursor...]) + Array(records[..<cursor])
    return Array(rotated.prefix(Self.reviewStatusPollingLimitPerProfile))
  }

  public func reviewPollingEligibleRecordCount(
    for profileID: UUID,
    store: WorkbenchStore,
    includeLegacyRecords: Bool = false
  ) -> Int {
    reviewPollingEligibleRecordsUnbounded(
      for: profileID,
      store: store,
      includeLegacyRecords: includeLegacyRecords
    ).count
  }

  @discardableResult
  public func refreshRemoteReviewStatus(
    for record: ReleaseRecord,
    store: WorkbenchStore,
    updatesMessage: Bool = true,
    checkedAt: Date = Date()
  ) async throws -> RemoteRepositoryReviewStatusSnapshot {
    let profile = store.profile(for: record)
    let updatesProfileUI = updatesMessage
    let requestID = UUID()
    latestReviewStatusRequestIDByRecord[record.id] = requestID
    if updatesProfileUI {
      activeReviewStatusRequestIDsByProfileID[profile.id, default: []].insert(requestID)
      refreshDeploymentStatusChecking(for: profile.id)
      setDeploymentStatusMessage(
        CoreL10n.text("正在检查 PR/MR 合并状态..."),
        for: profile.id
      )
    }
    defer {
      if updatesProfileUI {
        activeReviewStatusRequestIDsByProfileID[profile.id]?.remove(requestID)
        if activeReviewStatusRequestIDsByProfileID[profile.id]?.isEmpty == true {
          activeReviewStatusRequestIDsByProfileID.removeValue(forKey: profile.id)
        }
      }
      if latestReviewStatusRequestIDByRecord[record.id] == requestID {
        latestReviewStatusRequestIDByRecord.removeValue(forKey: record.id)
      }
      if updatesProfileUI {
        refreshDeploymentStatusChecking(for: profile.id)
      }
    }

    do {
      guard let token = try repositoryTokenStore.repositoryToken(for: profile) else {
        throw RemoteRepositoryPublishError.missingToken
      }
      let snapshot = try await remoteRepositoryPublishService.reviewStatus(
        for: record,
        profile: profile,
        token: token,
        checkedAt: checkedAt
      )
      guard latestReviewStatusRequestIDByRecord[record.id] == requestID,
        store.profiles.first(where: { $0.id == profile.id }) == profile,
        store.releaseRecords.contains(where: { $0.id == record.id })
      else {
        throw CancellationError()
      }
      try applyRemoteReviewStatus(snapshot, matching: record, store: store)
      if updatesProfileUI {
        setDeploymentStatusMessage(reviewStatusMessage(snapshot, record: record), for: profile.id)
      }
      store.save()
      return snapshot
    } catch {
      if updatesProfileUI,
        !Task.isCancelled,
        !(error is CancellationError)
      {
        setDeploymentStatusMessage(
          CoreL10n.format("PR/MR 状态检查失败：%@", error.localizedDescription),
          for: profile.id
        )
      }
      throw error
    }
  }

  private func reviewStatusMessage(
    _ snapshot: RemoteRepositoryReviewStatusSnapshot,
    record: ReleaseRecord
  ) -> String {
    guard snapshot.state == .merged,
      let observedHead = snapshot.headCommitSHA?.trimmedForPublishing.nilIfEmpty,
      let originalHead = record.commitSHA?.trimmedForPublishing.nilIfEmpty,
      observedHead.caseInsensitiveCompare(originalHead) != .orderedSame,
      observedHead.caseInsensitiveCompare(
        record.acceptedReviewHeadCommitSHA?.trimmedForPublishing ?? "")
        != .orderedSame
    else { return snapshot.message }
    return CoreL10n.text("PR/MR 已合并，但 head commit 已漂移；请先确认新的 Review Commit，才会开始部署归因。")
  }

  private func applyRemoteReviewStatus(
    _ snapshot: RemoteRepositoryReviewStatusSnapshot,
    matching record: ReleaseRecord,
    store: WorkbenchStore
  ) throws {
    guard snapshot.provider == record.repositoryProvider,
      record.reviewNumber == nil || snapshot.reviewNumber == record.reviewNumber,
      snapshot.reviewURL == record.reviewURL,
      snapshot.sourceBranch == record.branchName,
      snapshot.targetBranch == record.targetBranch
    else { throw RemoteRepositoryPublishError.invalidResponse }
    var didApply = false
    for index in store.publishingStore.releaseRecords.indices {
      let candidate = store.publishingStore.releaseRecords[index]
      guard candidate.id == record.id,
        candidate.kind == .remoteReviewRequest,
        candidate.siteProfileID == record.siteProfileID,
        candidate.repositoryProvider == record.repositoryProvider,
        candidate.repositoryBaseURL == record.repositoryBaseURL,
        candidate.repoOwner == record.repoOwner,
        candidate.repoName == record.repoName,
        candidate.reviewNumber == record.reviewNumber,
        candidate.reviewURL == record.reviewURL,
        candidate.branchName == record.branchName,
        candidate.targetBranch == record.targetBranch,
        candidate.commitSHA == record.commitSHA
      else {
        continue
      }

      var updated = candidate
      updated.reviewNumber = snapshot.reviewNumber
      updated.reviewURL = snapshot.reviewURL
      updated.reviewStatus = snapshot
      if deploymentStatusSnapshots[updated.id]?.expectedCommitSHA != snapshot.mergeCommitSHA {
        deploymentStatusSnapshots.removeValue(forKey: updated.id)
        deploymentStatusHistory.removeValue(forKey: updated.id)
      }
      store.publishingStore.releaseRecords[index] = updated
      didApply = true
      break
    }
    guard didApply else { throw RemoteRepositoryPublishError.invalidResponse }
  }

  public func acceptObservedReviewHead(
    for record: ReleaseRecord,
    store: WorkbenchStore,
    acceptedAt: Date = Date()
  ) throws {
    guard let observedHead = record.reviewStatus?.headCommitSHA?.trimmedForPublishing.nilIfEmpty,
      record.hasUnconfirmedReviewHeadDrift,
      let index = store.publishingStore.releaseRecords.firstIndex(where: {
        $0.id == record.id && $0.commitSHA == record.commitSHA
          && $0.reviewStatus == record.reviewStatus
      })
    else { throw RemoteRepositoryPublishError.invalidResponse }
    store.publishingStore.releaseRecords[index].acceptedReviewHeadCommitSHA = observedHead
    store.publishingStore.releaseRecords[index].acceptedReviewHeadAt = acceptedAt
    deploymentStatusSnapshots.removeValue(forKey: record.id)
    deploymentStatusHistory.removeValue(forKey: record.id)
    store.save()
  }

  public func releaseLedger(store: WorkbenchStore) -> ReleaseLedger {
    releaseLedgerService.ledger(
      releaseRecords: store.releaseRecords,
      deploymentStatusSnapshots: deploymentStatusSnapshots
    )
  }

  public func activeProfileReleaseRecords(store: WorkbenchStore) -> [ReleaseRecord] {
    store.releaseRecords
      .filter { $0.siteProfileID == nil || $0.siteProfileID == store.activeProfileID }
      .sorted { $0.createdAt > $1.createdAt }
  }

  public func activeProfileDeploymentStatusSnapshots(store: WorkbenchStore) -> [UUID:
    DeploymentStatusSnapshot]
  {
    let activeRecords = activeProfileReleaseRecords(store: store)
    return activeProfileDeploymentStatusSnapshots(for: activeRecords)
  }

  public func activeProfileReleaseLedger(store: WorkbenchStore) -> ReleaseLedger {
    let activeRecords = activeProfileReleaseRecords(store: store)
    return releaseLedgerService.ledger(
      releaseRecords: activeRecords,
      deploymentStatusSnapshots: activeProfileDeploymentStatusSnapshots(for: activeRecords),
      repositoryHistory: store.localRepositoryReleaseHistory,
      repositoryProfile: store.activeProfile
    )
  }

  private func activeProfileDeploymentStatusSnapshots(
    for activeRecords: [ReleaseRecord]
  ) -> [UUID: DeploymentStatusSnapshot] {
    let activeRecordIDs = Set(activeRecords.map(\.id))
    return deploymentStatusSnapshots.filter { activeRecordIDs.contains($0.key) }
  }

  public func releaseLedgerEntry(for record: ReleaseRecord) -> ReleaseLedgerEntry {
    releaseLedgerService.ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: deploymentStatusSnapshots
    ).entries.first
      ?? ReleaseLedgerEntry(
        id: record.id,
        record: record,
        status: .unknown,
        statusMessage: CoreL10n.text("未找到发布账本记录。"),
        deploymentStatus: deploymentStatusSnapshots[record.id],
        rollbackDraft: nil
      )
  }

  public func releaseRecoveryVerificationDraftMarkdown(store: WorkbenchStore) -> String {
    activeProfileReleaseLedger(store: store).remoteRecoveryVerificationDraftMarkdown
  }

  public func deploymentPollingEligibleRecords(store: WorkbenchStore) -> [ReleaseRecord] {
    deploymentPollingEligibleRecords(
      for: store.activeProfileID, store: store, includeLegacyRecords: true)
  }

  /// Returns records explicitly bound to one site. Legacy records without a
  /// profile ID remain visible only for the active-site compatibility path;
  /// background polling never guesses their owner.
  public func deploymentPollingEligibleRecords(
    for profileID: UUID,
    store: WorkbenchStore,
    includeLegacyRecords: Bool = false
  ) -> [ReleaseRecord] {
    let allowLegacyRecords = includeLegacyRecords && profileID == store.activeProfileID
    let records = store.releaseRecords.filter { record in
      record.siteProfileID == profileID || (allowLegacyRecords && record.siteProfileID == nil)
    }
    let ledger = releaseLedgerService.ledger(
      releaseRecords: records,
      deploymentStatusSnapshots: activeProfileDeploymentStatusSnapshots(for: records)
    )
    let entriesByID = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.id, $0) })
    return records.compactMap { record in
      guard let entry = entriesByID[record.id],
        canPollDeploymentStatus(for: entry.status),
        canCheckDeploymentStatus(for: record, store: store)
      else {
        return nil
      }
      return record
    }
  }

  public func updateDeploymentPollingSettings(
    _ settings: DeploymentPollingSettings,
    store: WorkbenchStore
  ) {
    updateDeploymentPollingSettings(settings, for: store.activeProfileID, store: store)
  }

  public func updateDeploymentPollingSettings(
    _ settings: DeploymentPollingSettings,
    for profileID: UUID,
    store: WorkbenchStore
  ) {
    guard store.profiles.contains(where: { $0.id == profileID }) else { return }
    deploymentPollingGenerationByProfileID[profileID, default: 0] &+= 1
    let normalized = DeploymentPollingSettings(
      isEnabled: settings.isEnabled,
      intervalMinutes: settings.normalizedIntervalMinutes
    )
    var state = deploymentPollingStateByProfileID[profileID] ?? .idle
    if normalized.isEnabled {
      let now = Date()
      state.nextRunAt = normalized.nextRunDate(after: now)
      if state.lastRunAt == nil {
        state.message = CoreL10n.format(
          "远端发布状态自动检查已开启；将持续检查 PR/MR 合并与部署结果，最短间隔 %@ 分钟。",
          String(normalized.normalizedIntervalMinutes)
        )
      }
    } else {
      state = DeploymentPollingState(
        status: .disabled,
        message: CoreL10n.text("远端发布状态自动检查已关闭。")
      )
    }
    deploymentPollingSettingsByProfileID[profileID] = normalized
    deploymentPollingStateByProfileID[profileID] = state
    if profileID == boundAutomationProfileID {
      deploymentPollingSettings = normalized
      deploymentPollingState = state
    }
    store.save()
  }

  public func deploymentPollingSettings(for profileID: UUID) -> DeploymentPollingSettings {
    deploymentPollingSettingsByProfileID[profileID] ?? .default
  }

  public func deploymentPollingState(for profileID: UUID) -> DeploymentPollingState {
    deploymentPollingStateByProfileID[profileID] ?? .idle
  }

  /// Rebinds the compatibility scalar view without selecting a profile in the
  /// publishing store. This is also the bounded map cleanup point for deleted
  /// profiles.
  func setActiveProfile(_ profileID: UUID, validProfileIDs: Set<UUID>) {
    if let boundAutomationProfileID {
      deploymentPollingSettingsByProfileID[boundAutomationProfileID] = deploymentPollingSettings
      deploymentPollingStateByProfileID[boundAutomationProfileID] = deploymentPollingState
      if let deploymentStatusMessage {
        deploymentStatusMessageByProfileID[boundAutomationProfileID] = deploymentStatusMessage
      } else {
        deploymentStatusMessageByProfileID.removeValue(forKey: boundAutomationProfileID)
      }
    }
    deploymentPollingSettingsByProfileID = deploymentPollingSettingsByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    deploymentPollingStateByProfileID = deploymentPollingStateByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    deploymentPollingGenerationByProfileID = deploymentPollingGenerationByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    activeDeploymentStatusRequestIDsByProfileID = activeDeploymentStatusRequestIDsByProfileID.filter
    {
      validProfileIDs.contains($0.key)
    }
    activeReviewStatusRequestIDsByProfileID = activeReviewStatusRequestIDsByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    activeDeploymentPollingProfileIDs.formIntersection(validProfileIDs)
    deploymentStatusMessageByProfileID = deploymentStatusMessageByProfileID.filter {
      validProfileIDs.contains($0.key)
    }
    for profileID in validProfileIDs {
      deploymentPollingSettingsByProfileID[profileID] =
        deploymentPollingSettingsByProfileID[profileID] ?? .default
      deploymentPollingStateByProfileID[profileID] =
        deploymentPollingStateByProfileID[profileID] ?? .idle
    }
    boundAutomationProfileID = profileID
    deploymentPollingSettings = deploymentPollingSettingsByProfileID[profileID] ?? .default
    deploymentPollingState = deploymentPollingStateByProfileID[profileID] ?? .idle
    deploymentStatusMessage = deploymentStatusMessageByProfileID[profileID]
    refreshDeploymentStatusChecking(for: profileID)
  }

  @discardableResult
  public func tickDeploymentPolling(
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    await tickDeploymentPolling(for: store.activeProfileID, store: store, now: now)
  }

  @discardableResult
  public func tickDeploymentPolling(
    for profileID: UUID,
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    let settings = deploymentPollingSettings(for: profileID)
    let state = deploymentPollingState(for: profileID)
    guard settings.isDue(lastRunAt: state.lastRunAt, now: now) else {
      return false
    }
    return await runDeploymentPolling(for: profileID, store: store, now: now)
  }

  @discardableResult
  public func runDeploymentPolling(
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    await runDeploymentPolling(for: store.activeProfileID, store: store, now: now)
  }

  @discardableResult
  public func runDeploymentPolling(
    for profileID: UUID,
    store: WorkbenchStore,
    now: Date = Date()
  ) async -> Bool {
    guard !activeDeploymentPollingProfileIDs.contains(profileID),
      let frozenProfile = store.profiles.first(where: { $0.id == profileID })
    else {
      return false
    }
    activeDeploymentPollingProfileIDs.insert(profileID)
    refreshDeploymentStatusChecking(for: profileID)
    defer {
      activeDeploymentPollingProfileIDs.remove(profileID)
      refreshDeploymentStatusChecking(for: profileID)
    }
    let settings = deploymentPollingSettings(for: profileID)
    guard settings.isEnabled else {
      setPollingState(
        DeploymentPollingState(
          status: .disabled,
          message: CoreL10n.text("远端发布状态自动检查已关闭。")
        ),
        for: profileID
      )
      store.save()
      return false
    }
    let runGeneration = beginDeploymentPollingRun(for: profileID)

    // A nil siteProfileID is a legacy record whose owner can only be inferred
    // from the active compatibility view. Background profiles must never
    // claim such records for themselves.
    let reviewRecords = reviewPollingEligibleRecords(
      for: profileID,
      store: store,
      includeLegacyRecords: profileID == store.activeProfileID
    )
    let reviewRecordCount = reviewPollingEligibleRecordsUnbounded(
      for: profileID, store: store, includeLegacyRecords: profileID == store.activeProfileID
    ).count
    let initialDeploymentRecords = deploymentPollingEligibleRecords(
      for: profileID,
      store: store,
      includeLegacyRecords: profileID == store.activeProfileID
    )
    guard !reviewRecords.isEmpty || !initialDeploymentRecords.isEmpty else {
      setPollingState(
        DeploymentPollingState(
          status: .noEligibleRecords,
          lastRunAt: now,
          nextRunAt: settings.nextRunDate(after: now),
          checkedRecordCount: 0,
          checkedRecords: [],
          message: CoreL10n.text("当前没有需要轮询的 PR/MR 或部署记录。")
        ),
        for: profileID
      )
      store.save()
      return true
    }

    var reviewCheckedCount = 0
    var reviewMergedCount = 0
    var reviewClosedCount = 0
    var reviewFailureCount = 0
    var reviewFailures: [DeploymentPollingReviewFailureSummary] = []
    for record in reviewRecords {
      do {
        let snapshot = try await refreshRemoteReviewStatus(
          for: record,
          store: store,
          updatesMessage: false,
          checkedAt: now
        )
        reviewCheckedCount += 1
        switch snapshot.state {
        case .merged:
          reviewMergedCount += 1
        case .closedWithoutMerge:
          reviewClosedCount += 1
        case .open, .locked:
          break
        }
      } catch is CancellationError {
        return false
      } catch {
        guard !Task.isCancelled else { return false }
        reviewFailureCount += 1
        if reviewFailures.count < Self.reviewFailureSummaryLimit {
          reviewFailures.append(
            DeploymentPollingReviewFailureSummary(
              recordID: record.id,
              title: record.draftTitle ?? record.title,
              reviewURL: record.reviewURL,
              message: error.localizedDescription,
              checkedAt: now
            )
          )
        }
      }

      guard
        isCurrentDeploymentPollingRun(
          profileID: profileID,
          generation: runGeneration,
          settings: settings,
          frozenProfile: frozenProfile,
          store: store
        )
      else {
        return false
      }
    }
    if reviewRecordCount > 0 {
      reviewPollingCursorByProfileID[profileID] =
        (reviewPollingCursorByProfileID[profileID, default: 0] + reviewRecords.count)
        % reviewRecordCount
    }

    // Re-evaluate after Review checks. A record becomes deployment-eligible
    // only after a verified merged state supplied a target-branch commit.
    let deploymentRecords = deploymentPollingEligibleRecords(
      for: profileID,
      store: store,
      includeLegacyRecords: profileID == store.activeProfileID
    )
    var deploymentCheckedCount = 0
    var checkedRecords: [DeploymentPollingRecordSummary] = []
    for record in deploymentRecords {
      if let snapshot = await refreshDeploymentStatus(
        for: record, store: store, updatesMessage: false)
      {
        guard
          isCurrentDeploymentPollingRun(
            profileID: profileID,
            generation: runGeneration,
            settings: settings,
            frozenProfile: frozenProfile,
            store: store
          )
        else {
          return false
        }
        let releaseStatus = releaseLedgerService.ledger(
          releaseRecords: [record],
          deploymentStatusSnapshots: activeProfileDeploymentStatusSnapshots(for: [record])
        ).entries.first { $0.id == record.id }?.status
        deploymentCheckedCount += 1
        checkedRecords.append(
          DeploymentPollingRecordSummary(
            recordID: record.id,
            title: record.draftTitle ?? record.title,
            releaseStatus: releaseStatus,
            provider: snapshot.provider,
            level: snapshot.level,
            message: snapshot.message,
            checkedAt: snapshot.checkedAt
          )
        )
      }
    }

    guard
      isCurrentDeploymentPollingRun(
        profileID: profileID,
        generation: runGeneration,
        settings: settings,
        frozenProfile: frozenProfile,
        store: store
      )
    else {
      return false
    }

    let state = DeploymentPollingState(
      status: pollingStatus(
        reviewCheckedCount: reviewCheckedCount,
        deploymentCheckedCount: deploymentCheckedCount,
        reviewFailureCount: reviewFailureCount
      ),
      lastRunAt: now,
      nextRunAt: settings.nextRunDate(after: now),
      checkedRecordCount: reviewCheckedCount + deploymentCheckedCount,
      checkedRecords: checkedRecords,
      reviewCheckedRecordCount: reviewCheckedCount,
      reviewMergedCount: reviewMergedCount,
      reviewClosedCount: reviewClosedCount,
      reviewFailureCount: reviewFailureCount,
      reviewFailureRecords: reviewFailures,
      message: deploymentPollingMessage(
        checkedCount: deploymentCheckedCount,
        checkedRecords: checkedRecords,
        reviewCheckedCount: reviewCheckedCount,
        reviewMergedCount: reviewMergedCount,
        reviewClosedCount: reviewClosedCount,
        reviewFailureCount: reviewFailureCount
      )
    )
    setPollingState(state, for: profileID)
    setDeploymentStatusMessage(state.message, for: profileID)
    store.save()
    return true
  }

  private func reviewPollingEligibleRecordsUnbounded(
    for profileID: UUID,
    store: WorkbenchStore,
    includeLegacyRecords: Bool
  ) -> [ReleaseRecord] {
    let allowLegacyRecords = includeLegacyRecords && profileID == store.activeProfileID
    return store.releaseRecords.filter { record in
      record.kind == .remoteReviewRequest
        && record.reviewStatus?.state != .merged
        && record.reviewURL?.trimmedForPublishing.nilIfEmpty != nil
        && record.branchName?.trimmedForPublishing.nilIfEmpty != nil
        && record.targetBranch?.trimmedForPublishing.nilIfEmpty != nil
        && record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
        && (record.siteProfileID == profileID
          || (allowLegacyRecords && record.siteProfileID == nil))
    }.sorted { lhs, rhs in
      lhs.createdAt == rhs.createdAt
        ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt
    }
  }

  private func pollingStatus(
    reviewCheckedCount: Int,
    deploymentCheckedCount: Int,
    reviewFailureCount: Int
  ) -> DeploymentPollingStatus {
    if reviewFailureCount == 0 { return .checked }
    return reviewCheckedCount + deploymentCheckedCount > 0 ? .partial : .failed
  }

  private func setPollingState(_ state: DeploymentPollingState, for profileID: UUID) {
    deploymentPollingStateByProfileID[profileID] = state
    if profileID == boundAutomationProfileID {
      deploymentPollingState = state
    }
  }

  /// Runtime activity is intentionally profile-scoped. A request started for
  /// a background site must neither keep the selected site's progress control
  /// spinning nor clear it when that selected site has its own work.
  private func refreshDeploymentStatusChecking(for profileID: UUID) {
    guard profileID == boundAutomationProfileID else { return }
    isDeploymentStatusChecking =
      !(activeDeploymentStatusRequestIDsByProfileID[profileID] ?? []).isEmpty
      || !(activeReviewStatusRequestIDsByProfileID[profileID] ?? []).isEmpty
      || activeDeploymentPollingProfileIDs.contains(profileID)
  }

  private func setDeploymentStatusMessage(_ message: String?, for profileID: UUID) {
    if let message {
      deploymentStatusMessageByProfileID[profileID] = message
    } else {
      deploymentStatusMessageByProfileID.removeValue(forKey: profileID)
    }
    if profileID == boundAutomationProfileID {
      deploymentStatusMessage = message
    }
  }

  private func beginDeploymentPollingRun(for profileID: UUID) -> UInt64 {
    deploymentPollingGenerationByProfileID[profileID, default: 0] &+= 1
    return deploymentPollingGenerationByProfileID[profileID] ?? 0
  }

  private func isCurrentDeploymentPollingRun(
    profileID: UUID,
    generation: UInt64,
    settings: DeploymentPollingSettings,
    frozenProfile: SiteProfile,
    store: WorkbenchStore
  ) -> Bool {
    deploymentPollingGenerationByProfileID[profileID] == generation
      && deploymentPollingSettings(for: profileID) == settings
      && store.profiles.first(where: { $0.id == profileID }) == frozenProfile
  }

  public func canCheckDeploymentStatus(
    for record: ReleaseRecord,
    store: WorkbenchStore
  ) -> Bool {
    guard releaseCanHaveDeployment(record) else { return false }
    return deploymentStatusReadiness(for: record, store: store).canCheckAnyStatus
  }

  private func releaseCanHaveDeployment(_ record: ReleaseRecord) -> Bool {
    switch record.kind {
    case .remoteDirectCommit, .remoteRollback:
      return true
    case .remoteReviewRequest:
      return record.reviewStatus?.state == .merged
        && record.deploymentCommitSHA != nil
    case .remotePublishFailure:
      guard record.commitSHA?.trimmedForPublishing.nilIfEmpty != nil else { return false }
      let branch = record.branchName?.trimmedForPublishing.nilIfEmpty
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
      return targetBranch == nil || branch == nil || branch == targetBranch
    case .localWrite,
      .batchLocalWrite,
      .directCommit,
      .reviewBranch,
      .remotePreviewBranch,
      .remoteReviewWithdrawal:
      return false
    }
  }

  @discardableResult
  public func refreshDeploymentStatus(
    for record: ReleaseRecord,
    store: WorkbenchStore,
    updatesMessage: Bool = true
  ) async -> DeploymentStatusSnapshot? {
    let profile = store.profile(for: record)
    let updatesProfileUI = updatesMessage
    guard canCheckDeploymentStatus(for: record, store: store) else {
      if updatesProfileUI {
        setDeploymentStatusMessage(
          deploymentStatusReadiness(for: record, store: store).nextStep,
          for: profile.id
        )
      }
      return nil
    }

    let requestID = UUID()
    latestDeploymentStatusRequestIDByRecord[record.id] = requestID
    if updatesProfileUI {
      activeDeploymentStatusRequestIDsByProfileID[profile.id, default: []].insert(requestID)
      refreshDeploymentStatusChecking(for: profile.id)
      setDeploymentStatusMessage(CoreL10n.text("正在检查部署状态..."), for: profile.id)
    }
    defer {
      if updatesProfileUI {
        activeDeploymentStatusRequestIDsByProfileID[profile.id]?.remove(requestID)
        if activeDeploymentStatusRequestIDsByProfileID[profile.id]?.isEmpty == true {
          activeDeploymentStatusRequestIDsByProfileID.removeValue(forKey: profile.id)
        }
      }
      if latestDeploymentStatusRequestIDByRecord[record.id] == requestID {
        latestDeploymentStatusRequestIDByRecord.removeValue(forKey: record.id)
      }
      if updatesProfileUI {
        refreshDeploymentStatusChecking(for: profile.id)
      }
    }

    let token: String?
    let tokenAccessFailureMessage: String?
    do {
      token = try deploymentAccessToken(for: profile)
      tokenAccessFailureMessage = nil
    } catch {
      token = nil
      tokenAccessFailureMessage = CoreL10n.format(
        "部署 Token 状态读取失败：%@",
        error.localizedDescription
      )
      if profile.id == store.activeProfile.id {
        deploymentTokenAvailability = KeychainTokenAvailability(accessFailure: error)
      }
      if updatesProfileUI {
        setDeploymentStatusMessage(tokenAccessFailureMessage, for: profile.id)
      }
      let fallbackReadiness = deploymentStatusReadiness(
        for: profile,
        hasToken: false
      )
      guard fallbackReadiness.canCheckAnyStatus else {
        return nil
      }
    }
    let snapshot = await deploymentStatusService.check(
      profile: profile,
      releaseRecord: record.deploymentAttributionRecord,
      token: token
    )
    guard latestDeploymentStatusRequestIDByRecord[record.id] == requestID else {
      return nil
    }
    guard store.profiles.first(where: { $0.id == profile.id }) == profile else {
      return nil
    }
    recordDeploymentStatusSnapshot(snapshot, for: record)
    if updatesProfileUI {
      let statusMessage = CoreL10n.format(
        "%@：%@",
        snapshot.provider.displayName,
        snapshot.level.displayName
      )
      setDeploymentStatusMessage(
        [tokenAccessFailureMessage, statusMessage]
          .compactMap { $0 }
          .joined(separator: "\n"),
        for: profile.id
      )
    }
    store.save()
    return snapshot
  }

  public func recordDeploymentStatusSnapshot(
    _ snapshot: DeploymentStatusSnapshot, for record: ReleaseRecord
  ) {
    deploymentStatusSnapshots[record.id] = snapshot
    deploymentStatusHistory[record.id] = Array(
      ([snapshot] + (deploymentStatusHistory[record.id] ?? []))
        .sorted { $0.checkedAt > $1.checkedAt }
        .prefix(Self.deploymentStatusHistoryLimitPerRecord)
    )
  }

  @discardableResult
  public func saveDeploymentAccessToken(_ token: String, store: WorkbenchStore) -> Bool {
    do {
      try deploymentTokenStore.saveToken(
        token.trimmedForPublishing,
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile),
        originURLText: deploymentCredentialOriginURLText(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      setDeploymentStatusMessage(
        CoreL10n.format(
          "%@ 部署 Token 已保存。",
          deploymentProvider(for: store.activeProfile).displayName
        ),
        for: store.activeProfileID
      )
      return true
    } catch {
      setDeploymentStatusMessage(
        CoreL10n.format("部署 Token 保存失败：%@", error.localizedDescription),
        for: store.activeProfileID
      )
      return false
    }
  }

  public func deleteDeploymentAccessToken(store: WorkbenchStore) {
    do {
      try deploymentTokenStore.deleteToken(
        for: store.activeProfile,
        scope: deploymentTokenScope(for: store.activeProfile),
        originURLText: deploymentCredentialOriginURLText(for: store.activeProfile)
      )
      refreshDeploymentTokenAvailability(store: store)
      setDeploymentStatusMessage(
        CoreL10n.format(
          "%@ 部署 Token 已删除。",
          deploymentProvider(for: store.activeProfile).displayName
        ),
        for: store.activeProfileID
      )
    } catch {
      setDeploymentStatusMessage(
        CoreL10n.format("部署 Token 删除失败：%@", error.localizedDescription),
        for: store.activeProfileID
      )
    }
  }

  public func refreshDeploymentTokenAvailability(store: WorkbenchStore) {
    let profile = store.activeProfile
    deploymentTokenAvailability = resolvedDeploymentTokenAvailability(for: profile)
    if let accessFailureMessage = deploymentTokenAvailability.accessFailureMessage {
      setDeploymentStatusMessage(
        CoreL10n.format("部署 Token 状态读取失败：%@", accessFailureMessage),
        for: profile.id
      )
    }
  }

  private func resolvedDeploymentTokenAvailability(
    for profile: SiteProfile
  ) -> KeychainTokenAvailability {
    do {
      return try deploymentTokenStore.availability(
        for: profile,
        scope: deploymentTokenScope(for: profile),
        originURLText: deploymentCredentialOriginURLText(for: profile)
      )
    } catch {
      return KeychainTokenAvailability(accessFailure: error)
    }
  }

  private func deploymentAccessToken(for profile: SiteProfile) throws -> String? {
    try deploymentTokenStore.token(
      for: profile,
      scope: deploymentTokenScope(for: profile),
      originURLText: deploymentCredentialOriginURLText(for: profile)
    )
  }

  private func deploymentTokenScope(for profile: SiteProfile) -> KeychainTokenScope {
    .deployment(deploymentProvider(for: profile))
  }

  private func deploymentProvider(for profile: SiteProfile) -> DeploymentProvider {
    if let provider = profile.deploymentProvider {
      return provider
    }
    return profile.repositoryProvider == .github ? .githubPages : .gitlabPages
  }

  private func deploymentCredentialOriginURLText(for profile: SiteProfile) -> String {
    switch deploymentProvider(for: profile) {
    case .githubPages:
      return profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.github.defaultBaseURL
    case .gitlabPages:
      return profile.repositoryBaseURL.nilIfEmpty ?? RepositoryProvider.gitlab.defaultBaseURL
    case .netlify:
      return "https://api.netlify.com"
    case .vercel:
      return "https://api.vercel.com"
    case .cloudflarePages:
      return "https://api.cloudflare.com"
    case .custom:
      return profile.deploymentStatusEndpointURL?.nilIfEmpty ?? ""
    }
  }

  private func deploymentPollingMessage(
    checkedCount: Int,
    checkedRecords: [DeploymentPollingRecordSummary],
    reviewCheckedCount: Int,
    reviewMergedCount: Int,
    reviewClosedCount: Int,
    reviewFailureCount: Int
  ) -> String {
    guard checkedCount > 0 || reviewCheckedCount > 0 || reviewFailureCount > 0 else {
      return CoreL10n.text("远端发布状态检查已运行，但没有成功取得可用结果。")
    }

    var sections: [String] = []
    if reviewCheckedCount > 0 {
      var reviewParts = [
        CoreL10n.format("已合并 %@", String(reviewMergedCount)),
        CoreL10n.format("未合并关闭 %@", String(reviewClosedCount)),
      ]
      let pendingCount = max(0, reviewCheckedCount - reviewMergedCount - reviewClosedCount)
      reviewParts.append(CoreL10n.format("等待中 %@", String(pendingCount)))
      sections.append(
        CoreL10n.format(
          "Review %@ 条（%@）",
          String(reviewCheckedCount),
          reviewParts.joined(separator: CoreL10n.text("，"))
        )
      )
    }
    if reviewFailureCount > 0 {
      sections.append(CoreL10n.format("Review 检查失败 %@ 条", String(reviewFailureCount)))
    }

    guard checkedCount > 0 else {
      return CoreL10n.format(
        "远端发布状态检查完成：%@。",
        sections.joined(separator: CoreL10n.text("；"))
      )
    }

    let successCount = checkedRecords.filter(\.isResolvedSuccess).count
    let runningCount = checkedRecords.filter { $0.level == .running }.count
    let failedCount = checkedRecords.filter { $0.level == .failed }.count
    let unknownCount = checkedRecords.filter { $0.level == .unknown }.count
    let remoteRecoveryCount = checkedRecords.filter(\.isPendingRemoteRecovery).count
    var parts = [
      CoreL10n.format("正常 %@", String(successCount)),
      CoreL10n.format("部署中 %@", String(runningCount)),
    ]
    if remoteRecoveryCount > 0 {
      parts.append(CoreL10n.format("远端恢复待确认 %@", String(remoteRecoveryCount)))
    }
    if failedCount > 0 {
      parts.append(CoreL10n.format("失败 %@", String(failedCount)))
    }
    if unknownCount > 0 {
      parts.append(CoreL10n.format("未知 %@", String(unknownCount)))
    }
    sections.append(
      CoreL10n.format(
        "部署 %@ 条（%@）",
        String(checkedCount),
        parts.joined(separator: CoreL10n.text("，"))
      )
    )
    return CoreL10n.format(
      "远端发布状态检查完成：%@。",
      sections.joined(separator: CoreL10n.text("；"))
    )
  }

  private func canPollDeploymentStatus(for status: ReleaseLedgerStatus) -> Bool {
    switch status {
    case .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .deploying, .unknown:
      return true
    case .localOnly, .previewOnly, .pendingReview, .reviewWithdrawn, .succeeded, .failed:
      return false
    }
  }
}
