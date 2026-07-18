import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class MonetizationTests: XCTestCase {
  func testFreePlanAllowsLimitedAIRequestsAndBlocksOnlinePublishing() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 2, onlinePublishAttemptLimit: 0, batchPublishLimit: 1))
    var state = MonetizationState.default

    XCTAssertTrue(service.accessDecision(for: .aiRequest, state: state).isAllowed)
    state = service.consuming(.aiRequest, state: state)
    XCTAssertEqual(service.remainingFreeUses(for: .aiRequest, usage: state.freeUsage), 1)
    state = service.consuming(.aiRequest, state: state)
    XCTAssertFalse(service.accessDecision(for: .aiRequest, state: state).isAllowed)

    let online = service.accessDecision(for: .onlinePublishing, state: state)
    XCTAssertFalse(online.isAllowed)
    XCTAssertTrue(online.requiresPro)
    XCTAssertTrue(online.message.contains(PremiumFeature.onlinePublishing.proBenefit))
    XCTAssertTrue(online.message.contains("Pro 设置"))
  }

  func testBlockedPremiumFeaturesIncludeActionableUpgradeCopy() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let state = MonetizationState.default

    for feature in PremiumFeature.allCases {
      let decision = service.accessDecision(for: feature, state: state)

      XCTAssertFalse(decision.isAllowed)
      XCTAssertTrue(decision.requiresPro)
      XCTAssertTrue(decision.message.contains(feature.proBenefit))
      XCTAssertTrue(decision.message.contains("购买或恢复"))
    }
  }

  func testUpgradeRequirementsExplainBlockedFreeBoundaries() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let state = MonetizationState.default

    let requirements = service.upgradeRequirements(state: state)

    XCTAssertEqual(requirements.map(\.feature), PremiumFeature.allCases)
    for requirement in requirements {
      XCTAssertTrue(requirement.isBlocking)
      XCTAssertTrue(requirement.summary.contains(requirement.feature.displayName))
      XCTAssertTrue(requirement.reason.contains(requirement.feature.proBenefit))
      XCTAssertEqual(requirement.quotaSummary, "已用 0/0，剩余 0 次")
      XCTAssertEqual(requirement.usedFreeUses, 0)
      XCTAssertEqual(requirement.freeLimit, 0)
      XCTAssertEqual(requirement.remainingFreeUses, 0)
      XCTAssertTrue(requirement.nextStep.contains("购买或恢复"))
      XCTAssertTrue(requirement.checklistLine.contains("需要 Pro"))
    }
  }

  func testUpgradeRequirementsShowRemainingFreeQuotaBeforeBlocking() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 2, onlinePublishAttemptLimit: 1, batchPublishLimit: 1))
    let state = MonetizationState.default

    let aiRequirement = service.upgradeRequirement(for: .aiRequest, state: state)
    let onlineRequirement = service.upgradeRequirement(for: .onlinePublishing, state: state)

    XCTAssertFalse(aiRequirement.isBlocking)
    XCTAssertEqual(aiRequirement.quotaSummary, "已用 0/2，剩余 2 次")
    XCTAssertEqual(aiRequirement.freeLimit, 2)
    XCTAssertEqual(aiRequirement.remainingFreeUses, 2)
    XCTAssertTrue(aiRequirement.nextStep.contains("继续试用"))
    XCTAssertFalse(onlineRequirement.isBlocking)
    XCTAssertEqual(onlineRequirement.quotaSummary, "已用 0/1，剩余 1 次")
  }

  func testUpgradeRequirementsExposeUsedLimitAndRemainingQuota() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 3, onlinePublishAttemptLimit: 1, batchPublishLimit: 2))
    let state = MonetizationState(
      freeUsage: FreePlanUsage(aiRequestCount: 2, onlinePublishAttemptCount: 1, batchPublishCount: 0)
    )

    let aiRequirement = service.upgradeRequirement(for: .aiRequest, state: state)
    let onlineRequirement = service.upgradeRequirement(for: .onlinePublishing, state: state)

    XCTAssertFalse(aiRequirement.isBlocking)
    XCTAssertEqual(aiRequirement.usedFreeUses, 2)
    XCTAssertEqual(aiRequirement.freeLimit, 3)
    XCTAssertEqual(aiRequirement.remainingFreeUses, 1)
    XCTAssertEqual(aiRequirement.quotaSummary, "已用 2/3，剩余 1 次")
    XCTAssertTrue(aiRequirement.summary.contains("已用 2/3"))

    XCTAssertTrue(onlineRequirement.isBlocking)
    XCTAssertEqual(onlineRequirement.usedFreeUses, 1)
    XCTAssertEqual(onlineRequirement.freeLimit, 1)
    XCTAssertEqual(onlineRequirement.remainingFreeUses, 0)
    XCTAssertEqual(onlineRequirement.quotaSummary, "已用 1/1，剩余 0 次")
    XCTAssertTrue(onlineRequirement.summary.contains("已用 1/1"))
  }

  func testStatusSummaryExplainsBlockedFreePlanAndCopyableChecklist() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let summary = service.statusSummary(state: .default)

    XCTAssertEqual(summary.title, "3 项功能需要 Pro")
    XCTAssertTrue(summary.isActionRequired)
    XCTAssertEqual(summary.blockedRequirements.count, 3)
    XCTAssertTrue(summary.message.contains("AI 请求"))
    XCTAssertTrue(summary.message.contains("GitHub/GitLab 线上发布"))
    XCTAssertTrue(summary.nextStep.contains("购买或恢复"))
    XCTAssertEqual(summary.systemImage, "lock.fill")
    XCTAssertTrue(summary.checklistMarkdown.contains("# Pro 状态摘要"))
    XCTAssertTrue(summary.checklistMarkdown.contains("- 状态：3 项功能需要 Pro"))
    XCTAssertTrue(summary.checklistMarkdown.contains("批量发布：需要 Pro"))
  }

  func testStatusSummaryShowsTrialAvailableBeforeBlocking() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 2, onlinePublishAttemptLimit: 1, batchPublishLimit: 1))
    let summary = service.statusSummary(state: .default)

    XCTAssertEqual(summary.title, "免费额度可用")
    XCTAssertFalse(summary.isActionRequired)
    XCTAssertTrue(summary.blockedRequirements.isEmpty)
    XCTAssertEqual(summary.availableRequirements.count, PremiumFeature.allCases.count)
    XCTAssertEqual(summary.systemImage, "person")
    XCTAssertTrue(summary.nextStep.contains("继续试用"))
  }

  func testStatusSummaryShowsUnlockedStoreKitEntitlement() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let state = MonetizationState(
      entitlement: ProEntitlementState(isUnlocked: true, source: .storeKit, productID: MonetizationProductCatalog.proLifetimeProductID),
      freeUsage: FreePlanUsage(aiRequestCount: 99, onlinePublishAttemptCount: 99, batchPublishCount: 99)
    )

    let summary = service.statusSummary(state: state)

    XCTAssertEqual(summary.title, "Pro 已解锁")
    XCTAssertFalse(summary.isActionRequired)
    XCTAssertTrue(summary.blockedRequirements.isEmpty)
    XCTAssertTrue(summary.message.contains("StoreKit 权益已生效"))
    XCTAssertTrue(summary.message.contains("不会消耗免费额度"))
    XCTAssertEqual(summary.systemImage, "crown.fill")
  }

  func testStoreExposesUpgradeRequirementsForSettingsAndGates() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      monetizationService: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      )
    )

    XCTAssertEqual(store.proUpgradeRequirements.count, PremiumFeature.allCases.count)
    XCTAssertTrue(store.proUpgradeRequirements.allSatisfy(\.isBlocking))
    XCTAssertEqual(store.proStatusSummary.title, "3 项功能需要 Pro")
    XCTAssertEqual(store.proUpgradeRequirement(for: .onlinePublishing).feature, .onlinePublishing)
    XCTAssertTrue(store.proUpgradeRequirement(for: .onlinePublishing).reason.contains("GitHub/GitLab API"))
  }











  func testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage() {
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let state = MonetizationState(
      entitlement: ProEntitlementState(isUnlocked: true, source: .storeKit, productID: MonetizationProductCatalog.proLifetimeProductID),
      freeUsage: FreePlanUsage(aiRequestCount: 10, onlinePublishAttemptCount: 5, batchPublishCount: 3)
    )

    XCTAssertTrue(service.accessDecision(for: .aiRequest, state: state).isAllowed)
    XCTAssertTrue(service.accessDecision(for: .onlinePublishing, state: state).isAllowed)
    XCTAssertTrue(service.accessDecision(for: .batchPublishing, state: state).isAllowed)
    XCTAssertEqual(service.consuming(.aiRequest, state: state).freeUsage.aiRequestCount, 10)
  }

	  func testStorePersistsUsageButRequiresStoreKitToReverifyEntitlementAfterRelaunch() async throws {
	    let url = try temporaryPersistenceURL()
	    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    _ = store.consumeFeatureUse(.aiRequest)
    store.applyVerifiedStoreKitEntitlement(productID: "test.pro")

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertEqual(reloaded.monetizationState.freeUsage.aiRequestCount, 1)
	    XCTAssertFalse(reloaded.monetizationState.entitlement.isUnlocked)
	    XCTAssertNil(reloaded.monetizationState.entitlement.productID)
	  }

	  func testBlockedPremiumFeatureRecordsUpgradeNoticeAndUnlockClearsIt() throws {
	    let store = WorkbenchStore(
	      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
	      monetizationService: MonetizationService(
	        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
	      )
	    )

	    let decision = store.consumeFeatureUse(.onlinePublishing)

	    XCTAssertFalse(decision.isAllowed)
	    XCTAssertEqual(store.latestProFeatureBlockNotice?.feature, .onlinePublishing)
	    XCTAssertEqual(store.latestProFeatureBlockNotice?.message, decision.message)
	    XCTAssertTrue(store.latestProFeatureBlockNotice?.nextStep.contains("Pro 设置") == true)

	    store.applyVerifiedStoreKitEntitlement(productID: "test.pro")

	    XCTAssertNil(store.latestProFeatureBlockNotice)
	    XCTAssertTrue(store.monetizationState.entitlement.isUnlocked)
	  }


	
  func testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.setMonetizationMessage("现有提示")

    store.markProEntitlementCheckCompleted(foundEntitlement: false)

    XCTAssertNotNil(store.monetizationState.entitlement.lastCheckedAt)
    XCTAssertEqual(store.monetizationMessage, "现有提示")
  }

  func testExplicitRestoreWithoutEntitlementKeepsUserFacingMessage() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))

    store.markProRestoreChecked(foundEntitlement: false)

    XCTAssertNotNil(store.monetizationState.entitlement.lastCheckedAt)
    XCTAssertEqual(store.monetizationMessage, "没有找到可恢复的 Pro 购买。")
  }

  func testBlockedAIChatSendDoesNotAppendUserMessage() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      monetizationService: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    let reply = await store.sendAIChatMessage("帮我检查标题", draft: draft)

    XCTAssertNil(reply)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertTrue(store.aiChatMessage?.contains("AI 请求已达到免费版边界") == true)
    XCTAssertTrue(store.aiChatMessage?.contains("已用 0/0") == true)
    XCTAssertTrue(store.aiChatMessage?.contains("购买或恢复") == true)
	    XCTAssertEqual(store.monetizationMessage, store.aiChatMessage)
	    XCTAssertEqual(store.latestProFeatureBlockNotice?.feature, .aiRequest)
	  }

  func testBlockedAIChatRegenerateKeepsExistingAssistantReply() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      monetizationService: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      )
    )
    let draft = try XCTUnwrap(store.selectedDraft)
    store.prepareAIChat(for: draft)
    let assistantMessage = AIPublishingChatMessage(role: .assistant, content: "已有回复")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "请检查"),
      assistantMessage,
    ])

    let reply = await store.regenerateLastAIChatReply(draft: draft)

    XCTAssertNil(reply)
    XCTAssertEqual(store.aiChatMessages.last, assistantMessage)
    XCTAssertTrue(store.aiChatMessage?.contains("AI 请求已达到免费版边界") == true)
    XCTAssertTrue(store.aiChatMessage?.contains("已用 0/0") == true)
    XCTAssertTrue(store.aiChatMessage?.contains("购买或恢复") == true)
  }

  func testMissingAIKeyChatDoesNotConsumeFreeQuotaOrAppendUserMessage() async throws {
    let (store, draft) = try storeWithMissingRequiredAIKey()

    let reply = await store.sendAIChatMessage("帮我检查标题", draft: draft)

    XCTAssertNil(reply)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.monetizationState.freeUsage.aiRequestCount, 0)
    XCTAssertTrue(store.aiChatMessage?.contains("请先在 Settings 的 AI 页保存 API Key") == true)
  }

  func testMissingAIKeyMetadataSuggestionDoesNotConsumeFreeQuota() async throws {
    let (store, draft) = try storeWithMissingRequiredAIKey()

    let suggestion = await store.generateAIMetadataSuggestions(draft: draft)

    XCTAssertNil(suggestion)
    XCTAssertNil(store.aiMetadataSuggestion)
    XCTAssertEqual(store.monetizationState.freeUsage.aiRequestCount, 0)
    XCTAssertTrue(store.aiActionMessage?.contains("请先在 Settings 的 AI 页保存 API Key") == true)
  }

  func testMissingAIKeyImageTextSuggestionDoesNotConsumeFreeQuota() async throws {
    let (store, draft) = try storeWithMissingRequiredAIKey(
      attachments: [
        DraftAttachment(
          originalFilename: "hero.jpg",
          relativePublishPath: "/images/hero.jpg",
          repositoryPath: "static/images/hero.jpg"
        ),
      ]
    )

    let suggestions = await store.generateAIImageTextSuggestions(draft: draft)

    XCTAssertTrue(suggestions.isEmpty)
    XCTAssertTrue(store.aiImageTextSuggestions.isEmpty)
    XCTAssertEqual(store.monetizationState.freeUsage.aiRequestCount, 0)
    XCTAssertTrue(store.imageActionMessage?.contains("请先在 Settings 的 AI 页保存 API Key") == true)
  }

  func testLegacySnapshotDecodesWithDefaultMonetizationState() throws {
    let profile = SiteProfile.defaultProfile
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")],
        releaseRecords: [],
        monetizationState: MonetizationState(
          entitlement: ProEntitlementState(isUnlocked: true, source: .storeKit, productID: "test.pro"),
          freeUsage: FreePlanUsage(aiRequestCount: 8)
        )
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "monetizationState")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertFalse(snapshot.monetizationState.entitlement.isUnlocked)
    XCTAssertEqual(snapshot.monetizationState.freeUsage.aiRequestCount, 0)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MonetizationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func storeWithMissingRequiredAIKey(
    attachments: [DraftAttachment] = []
  ) throws -> (WorkbenchStore, ArticleDraft) {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      monetizationService: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 1, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      ),
      keychainTokenStore: KeychainTokenStore(
        service: "PersonalSitePublisherMac.Tests.AI.\(UUID().uuidString)",
        accountPrefix: "ai-provider-tests",
        inMemory: true
      )
    )
    let profile = SiteProfile(
      id: UUID(),
      name: "No Key",
      aiProviderConfig: AIProviderConfig(
        preset: .deepSeek,
        baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
        model: AIProviderPreset.deepSeek.defaultModel,
        requiresAPIKey: true
      )
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "No Key Draft",
      slug: "no-key-draft",
      bodyMarkdown: "Body",
      attachments: attachments
    )

    store.updateActiveProfile(profile)
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    return (store, draft)
  }
}
