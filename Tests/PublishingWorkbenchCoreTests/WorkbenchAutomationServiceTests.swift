import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchAutomationServiceTests: XCTestCase {
  func testRegistryKeepsExternalCommandsBehindExplicitConfirmation() throws {
    let publish = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .publishOnline))
    let write = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .writeLocalRepository))
    let content = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .replaceBody))
    let preflight = try XCTUnwrap(WorkbenchAutomationRegistry.descriptor(for: .runPreflight))

    XCTAssertTrue(publish.risk.requiresExplicitConfirmation)
    XCTAssertFalse(publish.requiresDraft)
    XCTAssertTrue(write.risk.requiresExplicitConfirmation)
    XCTAssertTrue(content.risk.requiresExplicitConfirmation)
    XCTAssertFalse(preflight.risk.requiresExplicitConfirmation)
  }

  func testRegistryGeneratesClosedNativeToolSchemasFromTheCommandCatalog() throws {
    let definitions = WorkbenchAutomationRegistry.agentToolDefinitions

    XCTAssertEqual(
      definitions.map(\.function.name),
      WorkbenchAutomationRegistry.descriptors
        .filter { $0.id != .webSearch }
        .map { $0.id.rawValue }
    )
    XCTAssertTrue(definitions.allSatisfy { $0.type == "function" })
    for definition in definitions {
      guard case .object(let schema) = definition.function.parameters else {
        return XCTFail("Expected object schema for \(definition.function.name)")
      }
      XCTAssertEqual(schema["type"], .string("object"))
      XCTAssertEqual(schema["additionalProperties"], .bool(false))
      XCTAssertNotNil(schema["properties"])
      XCTAssertNotNil(schema["required"])
    }

    let openSection = try XCTUnwrap(
      definitions.first { $0.function.name == WorkbenchAutomationCommandID.openSection.rawValue }
    )
    guard case .object(let openSchema) = openSection.function.parameters,
      case .object(let properties)? = openSchema["properties"],
      case .object(let section)? = properties["section"],
      case .array(let sectionEnum)? = section["enum"]
    else {
      return XCTFail("Expected openSection section enum")
    }
    let advertisedSections = sectionEnum.compactMap { value -> String? in
      guard case .string(let raw) = value else { return nil }
      return raw
    }
    XCTAssertEqual(
      advertisedSections,
      WorkspaceVisibilityPolicy.commandPaletteSections.map(\.rawValue)
    )
    XCTAssertFalse(advertisedSections.contains(WorkspaceSection.images.rawValue))
    XCTAssertFalse(WorkbenchAutomationRegistry.promptCatalog.contains("section: images"))
  }

  func testEveryRegistryCommandSchemaParsesAndPassesTheSharedValidator() throws {
    let draftID = UUID()
    let now = Date()
    let draftVersions = [draftID: now]
    let argumentsByCommand: [WorkbenchAutomationCommandID: String] = [
      .openSection: #"{"section":"writing"}"#,
      .selectDraft: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .createDraft: #"{"value":"New draft"}"#,
      .focusEditor: #"{"draftID":"\#(draftID.uuidString)","editorField":"body"}"#,
      .showInspector: "{}",
      .runPreflight: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .refreshPublishPreview: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .saveWorkbench: "{}",
      .updateMetadata:
        #"{"draftID":"\#(draftID.uuidString)","metadataField":"title","value":"Title"}"#,
      .appendToBody: #"{"draftID":"\#(draftID.uuidString)","content":"Append"}"#,
      .replaceBody: #"{"draftID":"\#(draftID.uuidString)","content":"Replace"}"#,
      .deleteDraft: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .writeLocalRepository: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .publishOnline: "{}",
      .draftRead: #"{"draftID":"\#(draftID.uuidString)","mode":"full"}"#,
      .searchDrafts: #"{"query":"swift"}"#,
      .knowledgeSearch: #"{"query":"Swift concurrency"}"#,
      .knowledgeRead: #"{"documentID":"\#(UUID().uuidString)"}"#,
      .auditContent: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .applyDiff:
        #"{"draftID":"\#(draftID.uuidString)","originalText":"old","replacementText":"new"}"#,
      .generateFrontmatter: #"{"draftID":"\#(draftID.uuidString)","values":["swift"]}"#,
      .webFetch: #"{"url":"https://example.com"}"#,
      .webSearch: #"{"query":"swift"}"#,
      .siteCheckLinks: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .siteOptimizeImages: #"{"draftID":"\#(draftID.uuidString)"}"#,
      .siteDeployStatus: "{}",
    ]

    XCTAssertEqual(Set(argumentsByCommand.keys), Set(WorkbenchAutomationCommandID.allCases))
    for definition in WorkbenchAutomationRegistry.agentToolDefinitions {
      let command = try XCTUnwrap(
        WorkbenchAutomationCommandID(rawValue: definition.function.name)
      )
      let arguments = try XCTUnwrap(argumentsByCommand[command])
      let invocation = try WorkbenchAutomationRegistry.agentInvocation(
        for: AIToolCall(
          id: "roundtrip-\(command.rawValue)",
          function: AIToolFunctionCall(name: command.rawValue, arguments: arguments)
        ),
        draftVersions: draftVersions
      )

      XCTAssertEqual(invocation.step.command, command)
      XCTAssertNoThrow(try WorkbenchAutomationPlanValidator.validateArguments(invocation.step))
    }
  }

  func testAgentPermissionPolicyProducesAClosedToolAllowlist() throws {
    let legacyCommands = WorkbenchAutomationRegistry.agentCommands(
      allowedBy: .legacySafeDefault,
      masterEnabled: true
    )

    XCTAssertTrue(legacyCommands.contains(.draftRead))
    XCTAssertTrue(legacyCommands.contains(.searchDrafts))
    XCTAssertTrue(legacyCommands.contains(.knowledgeSearch))
    XCTAssertTrue(legacyCommands.contains(.knowledgeRead))
    XCTAssertTrue(legacyCommands.contains(.auditContent))
    XCTAssertTrue(legacyCommands.contains(.createDraft))
    XCTAssertFalse(legacyCommands.contains(.replaceBody))
    XCTAssertFalse(legacyCommands.contains(.webFetch))
    XCTAssertFalse(legacyCommands.contains(.siteDeployStatus))
    XCTAssertFalse(legacyCommands.contains(.writeLocalRepository))
    XCTAssertFalse(legacyCommands.contains(.publishOnline))
    XCTAssertFalse(legacyCommands.contains(.webSearch))

    XCTAssertTrue(
      WorkbenchAutomationRegistry.agentCommands(
        allowedBy: .all,
        masterEnabled: false
      ).isEmpty
    )
    let allExposed = WorkbenchAutomationRegistry.agentCommands(
      allowedBy: .all,
      masterEnabled: true
    )
    XCTAssertTrue(allExposed.contains(.siteDeployStatus))
    XCTAssertFalse(allExposed.contains(.webSearch))
  }

  func testUnimplementedWebSearchIsNotDeclaredOrAcceptedAsAnAgentTool() {
    XCTAssertFalse(
      WorkbenchAutomationRegistry.agentToolDefinitions.contains {
        $0.function.name == WorkbenchAutomationCommandID.webSearch.rawValue
      }
    )
    XCTAssertThrowsError(
      try WorkbenchAutomationRegistry.agentInvocation(
        for: AIToolCall(
          id: "hidden-search",
          function: AIToolFunctionCall(
            name: WorkbenchAutomationCommandID.webSearch.rawValue,
            arguments: #"{"query":"swift"}"#
          )
        ),
        draftVersions: [:]
      )
    )
  }

  func testMetadataConditionsUseTheSameParserAndValidatorRules() throws {
    let draftID = UUID()
    let draftVersions = [draftID: Date()]
    let validArguments = [
      #"{"draftID":"\#(draftID.uuidString)","metadataField":"tags","value":"swift"}"#,
      #"{"draftID":"\#(draftID.uuidString)","metadataField":"tags","values":["swift","macOS"]}"#,
    ]

    for (index, arguments) in validArguments.enumerated() {
      let invocation = try WorkbenchAutomationRegistry.agentInvocation(
        for: AIToolCall(
          id: "tags-\(index)",
          function: AIToolFunctionCall(name: "updateMetadata", arguments: arguments)
        ),
        draftVersions: draftVersions
      )
      XCTAssertNoThrow(try WorkbenchAutomationPlanValidator.validateArguments(invocation.step))
    }

    assertAgentArgumentsRejected(
      command: .updateMetadata,
      arguments: #"{"draftID":"\#(draftID.uuidString)","metadataField":"tags"}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .updateMetadata,
      arguments:
        #"{"draftID":"\#(draftID.uuidString)","metadataField":"title","values":["wrong"]}"#,
      draftVersions: draftVersions
    )
  }

  func testTagUpdateToolRejectsAnEmptyNoOp() {
    let draftID = UUID()
    assertAgentArgumentsRejected(
      command: .generateFrontmatter,
      arguments: #"{"draftID":"\#(draftID.uuidString)"}"#,
      draftVersions: [draftID: Date()]
    )
  }

  func testApplyDiffRequiresExactlyOneUnicodeSafeMatch() throws {
    let siteProfileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: siteProfileID,
      title: "局部修改",
      bodyMarkdown: "第一段 🧪正文\n\n第二段 🧪正文"
    )

    let repeated = WorkbenchAutomationStep(
      command: .applyDiff,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        originalText: "🧪正文",
        replacementText: "✅正文"
      )
    )
    XCTAssertThrowsError(
      try WorkbenchAutomationDraftMutationService.preview(step: repeated, draft: draft)
    )

    let missing = WorkbenchAutomationStep(
      command: .applyDiff,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        originalText: "不存在的片段",
        replacementText: "替换"
      )
    )
    XCTAssertThrowsError(
      try WorkbenchAutomationDraftMutationService.preview(step: missing, draft: draft)
    )

    var uniqueDraft = draft
    uniqueDraft.bodyMarkdown = "前缀 🧪正文 后缀"
    let unique = WorkbenchAutomationStep(
      command: .applyDiff,
      arguments: WorkbenchAutomationArguments(
        draftID: uniqueDraft.id,
        originalText: "🧪正文",
        replacementText: "✅正文"
      )
    )
    let preview = try WorkbenchAutomationDraftMutationService.preview(
      step: unique,
      draft: uniqueDraft
    )
    XCTAssertEqual(preview.updatedDraft.bodyMarkdown, "前缀 ✅正文 后缀")
  }

  func testAgentArgumentsRejectExtraNullAndInvalidEnumValues() {
    let draftID = UUID()
    let draftVersions = [draftID: Date()]

    assertAgentArgumentsRejected(
      command: .showInspector,
      arguments: #"{"extra":true}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .createDraft,
      arguments: #"{"value":null}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .openSection,
      arguments: #"{"section":"images"}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .focusEditor,
      arguments: #"{"draftID":"\#(draftID.uuidString)","editorField":"terminal"}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .knowledgeRead,
      arguments: #"{"documentID":"not-a-uuid"}"#,
      draftVersions: draftVersions
    )
    assertAgentArgumentsRejected(
      command: .updateMetadata,
      arguments: #"{"draftID":"\#(draftID.uuidString)","metadataField":"author","value":"x"}"#,
      draftVersions: draftVersions
    )

    let manuallyExtraneous = WorkbenchAutomationStep(
      command: .showInspector,
      arguments: WorkbenchAutomationArguments(value: "not allowed")
    )
    XCTAssertThrowsError(
      try WorkbenchAutomationPlanValidator.validateArguments(manuallyExtraneous)
    )
  }

  func testPublishPlanTargetsAllPendingSiteChangesInsteadOfCurrentDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationPublishPlan")
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
      <workbench_automation_plan>
      {"goal":"发布全部变更","steps":[{"command":"publishOnline","arguments":{}}]}
      </workbench_automation_plan>
      """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)
    let step = try XCTUnwrap(parsed.plan?.steps.first)

    XCTAssertEqual(step.command, .publishOnline)
    XCTAssertNil(step.arguments.draftID)
    XCTAssertNil(step.arguments.expectedDraftUpdatedAt)
  }

  func testParserExtractsValidatedPlanAndRemovesMachinePayloadFromVisibleReply() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationPlanParser")
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
      我可以先检查文章，再等待你确认是否修改摘要。
      <workbench_automation_plan>
      {
        "goal": "检查并补全摘要",
        "steps": [
          {"command": "runPreflight", "arguments": {"draftID": "\(draft.id.uuidString)"}},
          {"command": "updateMetadata", "arguments": {"draftID": "\(draft.id.uuidString)", "metadataField": "summary", "value": "新的文章摘要"}}
        ]
      }
      </workbench_automation_plan>
      """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)
    let plan = try XCTUnwrap(parsed.plan)

    XCTAssertEqual(parsed.displayContent, "我可以先检查文章，再等待你确认是否修改摘要。")
    XCTAssertEqual(plan.goal, "检查并补全摘要")
    XCTAssertEqual(plan.steps.map(\.command), [.runPreflight, .updateMetadata])
    XCTAssertEqual(plan.steps[0].arguments.draftID, draft.id)
    XCTAssertEqual(plan.steps[1].arguments.expectedDraftUpdatedAt, draft.updatedAt)
  }

  func testParserRejectsUnknownCommandInsteadOfGuessing() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationUnknownCommand")
    let draft = try XCTUnwrap(store.selectedDraft)
    let response = """
      <workbench_automation_plan>
      {"goal":"运行任意代码","steps":[{"command":"runShell","arguments":{"value":"rm -rf /"}}]}
      </workbench_automation_plan>
      """

    let parsed = WorkbenchAutomationPlanParser.parse(response, currentDraft: draft)

    XCTAssertNil(parsed.plan)
    XCTAssertTrue(parsed.displayContent.contains("runShell"))
  }

  func testExecutorRunsSafeStepWithoutConfirmation() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationSafeStep")
    let draft = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .runPreflight,
      arguments: WorkbenchAutomationArguments(draftID: draft.id)
    )
    let plan = WorkbenchAutomationPlan(goal: "检查文章", steps: [step])

    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(result.plan.steps.first?.status, .succeeded)
    XCTAssertEqual(result.record.steps.first?.status, .succeeded)
    XCTAssertEqual(store.selectedDraftID, draft.id)
  }

  func testAgentLoopPureReadOnlyPlanStillExecutesAllSteps() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentReadOnlyPlan")
    let draft = try XCTUnwrap(store.selectedDraft)
    let plan = WorkbenchAutomationPlan(
      goal: "读取并检查文章",
      steps: [
        WorkbenchAutomationStep(
          command: .draftRead,
          arguments: WorkbenchAutomationArguments(draftID: draft.id, mode: "outline")
        ),
        WorkbenchAutomationStep(
          command: .runPreflight,
          arguments: WorkbenchAutomationArguments(draftID: draft.id)
        ),
      ],
      source: .agentLoop
    )

    let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(result.plan.steps.map(\.status), [.succeeded, .succeeded])
    XCTAssertEqual(result.record.steps.map(\.status), [.succeeded, .succeeded])
  }

  func testAgentLoopConfirmationIsABarrierUntilEachStepIsResumed() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AgentConfirmationBarrier")
    let draft = try XCTUnwrap(store.selectedDraft)
    let mutation = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        content: "确认后追加的段落"
      )
    )
    let readOnly = WorkbenchAutomationStep(
      command: .runPreflight,
      arguments: WorkbenchAutomationArguments(draftID: draft.id)
    )
    let plan = WorkbenchAutomationPlan(
      goal: "先修改再检查",
      steps: [mutation, readOnly],
      source: .agentLoop
    )

    let blocked = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

    XCTAssertEqual(blocked.plan.steps[0].status, .awaitingConfirmation)
    XCTAssertEqual(blocked.plan.steps[1].status, .proposed)
    XCTAssertEqual(blocked.record.steps.map(\.status), [.awaitingConfirmation])
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)

    let confirmed = await WorkbenchAutomationExecutor.execute(
      plan: blocked.plan,
      in: store,
      onlyStepID: mutation.id,
      confirmedStepIDs: [mutation.id]
    )
    XCTAssertEqual(confirmed.plan.steps[0].status, .succeeded)
    XCTAssertEqual(confirmed.plan.steps[1].status, .proposed)
    XCTAssertTrue(store.selectedDraft?.bodyMarkdown.contains("确认后追加的段落") == true)

    let resumedReadOnly = await WorkbenchAutomationExecutor.execute(
      plan: confirmed.plan,
      in: store,
      onlyStepID: readOnly.id
    )
    XCTAssertEqual(resumedReadOnly.plan.steps[1].status, .succeeded)
    XCTAssertEqual(resumedReadOnly.record.steps.map(\.status), [.succeeded])
  }

  func testWebFetchRejectsLoopbackAndPrivateAddressesBeforeTransport() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "WebFetchSecurity")
    let blockedURLs = [
      "https://127.0.0.1/secret",
      "https://192.168.1.1/admin",
      "http://example.com/insecure",
    ]

    for blockedURL in blockedURLs {
      let step = WorkbenchAutomationStep(
        command: .webFetch,
        arguments: WorkbenchAutomationArguments(url: blockedURL)
      )
      let plan = WorkbenchAutomationPlan(
        goal: "抓取网页",
        steps: [step],
        source: .agentLoop
      )
      let result = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)

      XCTAssertEqual(result.plan.steps.first?.status, .failed, blockedURL)
      let message = result.record.steps.first?.message ?? ""
      XCTAssertTrue(
        message.contains("阻止")
          || message.contains("私网")
          || message.contains("本机")
          || message.contains("HTTPS"),
        message
      )
      XCTAssertFalse(message.contains("抓取完成") || message.contains("抓取已尝试"), message)
    }
  }

  func testContentMutationRequiresConfirmationAndCreatesRollbackVersion() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationContentMutation")
    let draft = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        content: "新增段落"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "追加段落", steps: [step])

    let unconfirmed = await WorkbenchAutomationExecutor.execute(plan: plan, in: store)
    XCTAssertEqual(unconfirmed.plan.steps.first?.status, .awaitingConfirmation)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)

    let confirmed = await WorkbenchAutomationExecutor.execute(
      plan: unconfirmed.plan,
      in: store,
      onlyStepID: step.id,
      confirmedStepIDs: Set([step.id])
    )
    XCTAssertEqual(confirmed.plan.steps.first?.status, .succeeded)
    XCTAssertTrue(store.selectedDraft?.bodyMarkdown.contains("新增段落") == true)
    XCTAssertNotNil(confirmed.record.steps.first?.rollbackVersionID)
    XCTAssertNotNil(confirmed.record.steps.first?.postMutationDraftFingerprint)
    XCTAssertNotNil(confirmed.record.steps.first?.postMutationDraftUpdatedAt)

    let restoredCount = WorkbenchAutomationExecutor.rollback(record: confirmed.record, in: store)
    XCTAssertEqual(restoredCount, 1)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)
  }

  func testRollbackRefusesToOverwriteEditsMadeAfterAgentMutation() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationRollbackDrift")
    let original = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .appendToBody,
      arguments: WorkbenchAutomationArguments(
        draftID: original.id,
        expectedDraftUpdatedAt: original.updatedAt,
        content: "Agent 段落"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "追加段落", steps: [step])
    let executed = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: store,
      confirmedStepIDs: [step.id]
    )
    var edited = try XCTUnwrap(store.selectedDraft)
    edited.bodyMarkdown += "\n\n用户稍后编辑"
    store.updateDraft(edited)

    let rollback = WorkbenchAutomationExecutor.rollbackDetailed(
      record: executed.record,
      in: store
    )

    XCTAssertEqual(rollback.restoredCount, 0)
    XCTAssertTrue(rollback.failureMessages.contains { $0.contains("已被编辑") })
    XCTAssertTrue(store.selectedDraft?.bodyMarkdown.contains("用户稍后编辑") == true)
  }

  func testExecutorRejectsContentMutationWhenDraftChangedAfterPlanning() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationStaleDraft")
    let original = try XCTUnwrap(store.selectedDraft)
    let step = WorkbenchAutomationStep(
      command: .updateMetadata,
      arguments: WorkbenchAutomationArguments(
        draftID: original.id,
        expectedDraftUpdatedAt: original.updatedAt,
        metadataField: .summary,
        value: "计划中的摘要"
      )
    )
    let plan = WorkbenchAutomationPlan(goal: "修改摘要", steps: [step])

    var changed = original
    changed.title = "另一窗口的新标题"
    store.updateDraft(changed)

    let result = await WorkbenchAutomationExecutor.execute(
      plan: plan,
      in: store,
      confirmedStepIDs: Set([step.id])
    )

    XCTAssertEqual(result.plan.steps.first?.status, .failed)
    XCTAssertEqual(store.selectedDraft?.summary, original.summary)
    XCTAssertTrue(result.record.steps.first?.message.contains("发生变化") == true)
  }

  func testAutomationRunHistoryRoundTripsInWorkbenchSnapshot() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AutomationHistory")
    let record = WorkbenchAutomationRunRecord(
      planID: UUID(),
      goal: "保存工作台",
      startedAt: Date(),
      steps: [
        WorkbenchAutomationStepRecord(
          command: .saveWorkbench,
          status: .succeeded,
          message: "工作台已保存。"
        )
      ]
    )
    let snapshot = WorkbenchSnapshot(
      profiles: store.profiles,
      activeProfileID: store.activeProfileID,
      drafts: store.drafts,
      releaseRecords: store.releaseRecords,
      automationRunRecords: [record]
    )

    let data = try JSONEncoder.workbench.encode(snapshot)
    let decoded = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)

    XCTAssertEqual(decoded.automationRunRecords.count, 1)
    XCTAssertEqual(decoded.automationRunRecords.first?.id, record.id)
    XCTAssertEqual(decoded.automationRunRecords.first?.planID, record.planID)
    XCTAssertEqual(decoded.automationRunRecords.first?.goal, record.goal)
    XCTAssertEqual(decoded.automationRunRecords.first?.steps.map(\.command), [.saveWorkbench])
    XCTAssertEqual(decoded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
  }

  func testLegacyMutationRecordWithoutPostconditionDoesNotAdvertiseUnsafeRollback() {
    let legacyRecord = WorkbenchAutomationRunRecord(
      planID: UUID(),
      goal: "旧版记录",
      startedAt: Date(),
      steps: [
        WorkbenchAutomationStepRecord(
          command: .replaceBody,
          status: .succeeded,
          message: "旧版修改",
          targetDraftID: UUID(),
          rollbackVersionID: UUID()
        )
      ]
    )

    XCTAssertFalse(legacyRecord.hasRollback)
  }

  func testFailedMutationRecordDoesNotAdvertiseRollbackEvenWithPostcondition() {
    let failedRecord = WorkbenchAutomationRunRecord(
      planID: UUID(),
      goal: "失败记录",
      startedAt: Date(),
      steps: [
        WorkbenchAutomationStepRecord(
          command: .createDraft,
          status: .failed,
          message: "failed",
          targetDraftID: UUID(),
          postMutationDraftFingerprint: "recorded-fingerprint"
        )
      ]
    )

    XCTAssertFalse(failedRecord.hasRollback)
  }

  private func assertAgentArgumentsRejected(
    command: WorkbenchAutomationCommandID,
    arguments: String,
    draftVersions: [UUID: Date],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try WorkbenchAutomationRegistry.agentInvocation(
        for: AIToolCall(
          id: "rejected-\(command.rawValue)",
          function: AIToolFunctionCall(name: command.rawValue, arguments: arguments)
        ),
        draftVersions: draftVersions
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? WorkbenchAutomationAgentToolError,
        .argumentMismatch,
        file: file,
        line: line
      )
    }
  }
}
