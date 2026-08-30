import PublishingWorkbenchCore
import SwiftUI

struct AIChatAutomationPlanCard: View {
  let message: AIPublishingChatMessage
  let plan: WorkbenchAutomationPlan
  let conversationID: UUID?
  let currentDraft: ArticleDraft
  let isChatRunning: Bool
  let isAutomationRunning: Bool
  let latestRunRecord: WorkbenchAutomationRunRecord?
  let actions: AIChatContextInspectorActions

  @State private var draftPreview: AutomationDraftPreviewItem?
  @State private var externalConfirmationStep: WorkbenchAutomationStep?
  @State private var isResolvingDeliveryUncertain = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("应用内操作计划", systemImage: "checklist.checked")
          .font(.callout.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.primary)
        Spacer(minLength: 8)
        statusLabel
      }

      Text(plan.goal)
        .font(.callout.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)

      if let continuation = message.agentContinuation,
        AIChatAgentReviewPresentation.isDeliveryUncertain(phase: continuation.phase)
      {
        deliveryUncertainNotice(continuation: continuation)
      } else if let continuation = message.agentContinuation,
        AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(phase: continuation.phase)
      {
        deliveryUncertainEndedNotice
      }

      VStack(spacing: 0) {
        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
          automationStepRow(index: index, step: step)
          if step.id != plan.steps.last?.id {
            Divider()
              .padding(.leading, 34)
          }
        }
      }
      .background(
        .background.opacity(0.52), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(.separator.opacity(0.7), lineWidth: 1)
      }

      if showsPlanActions {
        HStack(spacing: 8) {
          if hasExecutableSafeSteps {
            Button {
              guard let conversationID else { return }
              actions.executeAutomationPlan(conversationID, message.id)
            } label: {
              Label("执行安全步骤", systemImage: "play.fill")
            }
            .workbenchProminentActionStyle()
            .disabled(isBusy || conversationID == nil)
          }

          Button(role: .cancel) {
            guard let conversationID else { return }
            actions.cancelAutomationPlan(conversationID, message.id)
          } label: {
            Text("取消计划")
          }
          .disabled(isBusy || conversationID == nil)

          Spacer(minLength: 0)
        }
        .controlSize(.small)
      }

      if AIChatAgentReviewPresentation.allowsRollbackAction(
        phase: deliveryUncertainContinuationPhase
      ) {
        if let latestRunRecord, latestRunRecord.hasRollback {
          Button {
            actions.rollbackAutomationRun(latestRunRecord.id)
          } label: {
            Label("撤销本次本地修改", systemImage: "arrow.uturn.backward")
          }
          .controlSize(.small)
          .disabled(isBusy)
        } else if latestRunRecord?.rolledBackAt != nil {
          Label("本次本地修改已撤销", systemImage: "arrow.uturn.backward.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(11)
    .background(
      WorkbenchTheme.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(WorkbenchTheme.primary.opacity(0.22), lineWidth: 1)
    }
    .sheet(item: $draftPreview) { item in
      AIChatDraftDiffPreviewSheet(
        preview: AIChatDraftDiffPreview(
          originalDraft: item.preview.originalDraft,
          updatedDraft: item.preview.updatedDraft,
          citations: []
        ),
        isAgentReview: item.isAgentReview,
        onReject: item.isAgentReview
          ? {
            guard !isBusy, let conversationID else { return }
            actions.rejectAutomationStep(
              conversationID,
              message.id,
              item.stepID,
              item.preview.originalDraft.repositoryContentFingerprint
            )
          }
          : nil,
        onApply: {
          guard !isBusy, let conversationID else { return }
          if item.isAgentReview {
            actions.acceptAutomationStep(
              conversationID,
              message.id,
              item.stepID,
              item.preview.originalDraft.repositoryContentFingerprint
            )
          } else {
            actions.executeAutomationStep(conversationID, message.id, item.stepID)
          }
        }
      )
    }
    .confirmationDialog(
      externalConfirmationTitle,
      isPresented: Binding(
        get: { externalConfirmationStep != nil },
        set: { if !$0 { externalConfirmationStep = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let step = externalConfirmationStep,
        let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command)
      {
        Button(descriptor.title, role: .destructive) {
          externalConfirmationStep = nil
          guard !isBusy, let conversationID else { return }
          actions.executeAutomationStep(conversationID, message.id, step.id)
        }
      }
      Button("取消", role: .cancel) {
        externalConfirmationStep = nil
      }
    } message: {
      if let step = externalConfirmationStep,
        let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command)
      {
        Text(externalConfirmationMessage(for: step, descriptor: descriptor))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("应用内操作计划")
  }

  private var statusLabel: some View {
    Label(statusTitle, systemImage: statusSystemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(statusColor)
  }

  @ViewBuilder
  private func deliveryUncertainNotice(
    continuation: AIPublishingChatAgentContinuation
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        AIChatAgentReviewPresentation.deliveryUncertainWarning,
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout.weight(.semibold))
      .foregroundStyle(WorkbenchTheme.warning)

      Text(AIChatAgentReviewPresentation.deliveryUncertainDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Button {
          resolveDeliveryUncertain(
            continuation: continuation,
            branchConversation: false
          )
        } label: {
          Label(
            AIChatAgentReviewPresentation.deliveryUncertainAbandonTitle,
            systemImage: "checkmark.circle"
          )
        }
        .accessibilityIdentifier(
          AIChatAgentReviewPresentation.deliveryUncertainAbandonAccessibilityIdentifier
        )
        .accessibilityLabel(
          AIChatAgentReviewPresentation.deliveryUncertainAbandonTitle
        )
        .accessibilityHint("结束这次续跑并保留当前审计记录；不会重试。")
        .disabled(deliveryUncertainActionDisabled)

        Button {
          resolveDeliveryUncertain(
            continuation: continuation,
            branchConversation: true
          )
        } label: {
          Label(
            AIChatAgentReviewPresentation.deliveryUncertainBranchTitle,
            systemImage: "arrow.branch"
          )
        }
        .accessibilityIdentifier(
          AIChatAgentReviewPresentation.deliveryUncertainBranchAccessibilityIdentifier
        )
        .accessibilityLabel(
          AIChatAgentReviewPresentation.deliveryUncertainBranchTitle
        )
        .accessibilityHint("先结束当前续跑并保留审计记录，再从此消息创建新对话。")
        .disabled(deliveryUncertainActionDisabled)
      }
      .controlSize(.small)
    }
    .padding(9)
    .background(
      WorkbenchTheme.warning.opacity(0.10),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .stroke(WorkbenchTheme.warning.opacity(0.32), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      AIChatAgentReviewPresentation.deliveryUncertainAccessibilityIdentifier
    )
    .accessibilityLabel(
      AIChatAgentReviewPresentation.deliveryUncertainWarning
        + "。"
        + AIChatAgentReviewPresentation.deliveryUncertainDetail
    )
  }

  private var deliveryUncertainEndedNotice: some View {
    Label(
      AIChatAgentReviewPresentation.deliveryUncertainEndedTitle,
      systemImage: "checkmark.circle.fill"
    )
    .font(.caption.weight(.semibold))
    .foregroundStyle(WorkbenchTheme.success)
    .accessibilityIdentifier(
      AIChatAgentReviewPresentation.deliveryUncertainAccessibilityIdentifier
        + "-ended"
    )
    .accessibilityLabel(AIChatAgentReviewPresentation.deliveryUncertainEndedTitle)
    .accessibilityHint("当前续跑已结束，原审计记录仍然保留。")
  }

  private var deliveryUncertainContinuationPhase: AIPublishingChatAgentContinuationPhase? {
    message.agentContinuation?.phase
  }

  private var hasDeliveryUncertainResolutionState: Bool {
    guard let phase = deliveryUncertainContinuationPhase else { return false }
    return AIChatAgentReviewPresentation.isDeliveryUncertain(phase: phase)
      || AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(phase: phase)
  }

  private var deliveryUncertainActionDisabled: Bool {
    guard let phase = deliveryUncertainContinuationPhase else { return true }
    return isResolvingDeliveryUncertain
      || !AIChatAgentReviewPresentation.canResolveDeliveryUncertain(
        phase: phase,
        isBusy: isBusy,
        conversationID: conversationID
      )
  }

  private func resolveDeliveryUncertain(
    continuation: AIPublishingChatAgentContinuation,
    branchConversation: Bool
  ) {
    guard !deliveryUncertainActionDisabled,
      let conversationID
    else { return }

    isResolvingDeliveryUncertain = true
    let didAbandon = actions.abandonAgentContinuation(
      conversationID,
      message.id,
      continuation.planID,
      continuation.id,
      continuation.revision
    )
    guard didAbandon else {
      isResolvingDeliveryUncertain = false
      return
    }

    if branchConversation {
      actions.branchConversation(message.id, currentDraft)
    }
    isResolvingDeliveryUncertain = false
  }

  @ViewBuilder
  private func automationStepRow(index: Int, step: WorkbenchAutomationStep) -> some View {
    let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command)
    let isRunning = step.status == .running
    HStack(alignment: .top, spacing: 9) {
      AutomationStepStatusIndicator(status: step.status)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(index + 1). \(descriptor?.title ?? step.command.rawValue)")
            .font(.callout.weight(.medium))
          if let descriptor {
            Text(descriptor.risk.localizedDisplayName)
              .font(.workbenchMetadata)
              .foregroundStyle(riskColor(descriptor.risk))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(riskColor(descriptor.risk).opacity(0.10), in: Capsule())
          }
        }

        Text(step.resultMessage?.nilIfEmpty ?? descriptor?.detail ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let authorization = step.publishAuthorization {
          publishAuthorizationScope(authorization)
        }
      }

      Spacer(minLength: 8)

      if shouldOfferConfirmation(for: step), let descriptor {
        Button {
          handleConfirmation(for: step, risk: descriptor.risk)
        } label: {
          Text(confirmationButtonTitle(for: step, risk: descriptor.risk))
        }
        .controlSize(.small)
        .disabled(isBusy || conversationID == nil)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(
      isRunning
        ? WorkbenchTheme.primary.opacity(0.06)
        : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          isRunning ? WorkbenchTheme.primary.opacity(0.24) : Color.clear,
          lineWidth: 1
        )
    )
  }

  private func handleConfirmation(
    for step: WorkbenchAutomationStep,
    risk: WorkbenchAutomationRisk
  ) {
    guard !isBusy, let conversationID else { return }
    if step.command == .publishOnline,
      step.publishAuthorization == nil
    {
      actions.executeAutomationStep(conversationID, message.id, step.id)
    } else if risk == .contentChange {
      guard
        let preview = actions.previewAutomationStep(
          conversationID,
          message.id,
          step.id
        )
      else { return }
      draftPreview = AutomationDraftPreviewItem(
        stepID: step.id,
        preview: preview,
        isAgentReview: AIChatAgentReviewPresentation.isContentChangeReview(
          plan: plan,
          step: step
        )
      )
    } else {
      externalConfirmationStep = step
    }
  }

  private func shouldOfferConfirmation(for step: WorkbenchAutomationStep) -> Bool {
    guard !hasDeliveryUncertainResolutionState else { return false }
    guard step.status == .proposed || step.status == .awaitingConfirmation else { return false }
    return plan.requiresConfirmation(for: step)
  }

  private var hasExecutableSafeSteps: Bool {
    guard message.agentContinuation == nil else { return false }
    return plan.steps.contains { step in
      guard step.status == .proposed,
        WorkbenchAutomationRegistry.descriptor(for: step.command) != nil
      else { return false }
      return !plan.requiresConfirmation(for: step)
    }
  }

  private var isBusy: Bool {
    isChatRunning || isAutomationRunning
  }

  private var showsPlanActions: Bool {
    !hasDeliveryUncertainResolutionState
      && plan.steps.contains { !$0.status.isTerminal }
  }

  private var statusTitle: LocalizedStringKey {
    if let phase = deliveryUncertainContinuationPhase {
      if AIChatAgentReviewPresentation.isDeliveryUncertain(phase: phase) {
        return LocalizedStringKey(AIChatAgentReviewPresentation.deliveryUncertainWarning)
      }
      if AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(phase: phase) {
        return LocalizedStringKey(AIChatAgentReviewPresentation.deliveryUncertainEndedTitle)
      }
    }
    return switch plan.status {
    case .proposed: "待执行"
    case .running: "执行中"
    case .awaitingConfirmation: "等待确认"
    case .succeeded: "已完成"
    case .partiallySucceeded: "部分完成"
    case .failed: "已停止"
    case .cancelled: "已取消"
    }
  }

  private var statusSystemImage: String {
    if let phase = deliveryUncertainContinuationPhase {
      if AIChatAgentReviewPresentation.isDeliveryUncertain(phase: phase) {
        return "exclamationmark.triangle.fill"
      }
      if AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(phase: phase) {
        return "checkmark.circle.fill"
      }
    }
    return switch plan.status {
    case .proposed: "clock"
    case .running: "hourglass"
    case .awaitingConfirmation: "hand.raised"
    case .succeeded: "checkmark.circle.fill"
    case .partiallySucceeded: "circle.lefthalf.filled"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "slash.circle"
    }
  }

  private var statusColor: Color {
    if let phase = deliveryUncertainContinuationPhase {
      if AIChatAgentReviewPresentation.isDeliveryUncertain(phase: phase) {
        return WorkbenchTheme.warning
      }
      if AIChatAgentReviewPresentation.isDeliveryUncertainTerminal(phase: phase) {
        return WorkbenchTheme.success
      }
    }
    return switch plan.status {
    case .succeeded: WorkbenchTheme.success
    case .failed: WorkbenchTheme.risk
    case .awaitingConfirmation, .partiallySucceeded: WorkbenchTheme.warning
    case .proposed, .running: WorkbenchTheme.primary
    case .cancelled: .secondary
    }
  }

  private func stepStatusSystemImage(_ status: WorkbenchAutomationStepStatus) -> String {
    switch status {
    case .proposed: "circle"
    case .running: "hourglass"
    case .awaitingConfirmation: "hand.raised.fill"
    case .succeeded: "checkmark"
    case .failed: "xmark"
    case .cancelled: "slash"
    }
  }

  private func stepStatusColor(_ status: WorkbenchAutomationStepStatus) -> Color {
    switch status {
    case .succeeded: WorkbenchTheme.success
    case .failed: WorkbenchTheme.risk
    case .awaitingConfirmation: WorkbenchTheme.warning
    case .running, .proposed: WorkbenchTheme.primary
    case .cancelled: .secondary
    }
  }

  private func riskColor(_ risk: WorkbenchAutomationRisk) -> Color {
    switch risk {
    case .readOnly: WorkbenchTheme.primary
    case .reversible: WorkbenchTheme.success
    case .contentChange: WorkbenchTheme.warning
    case .externalEffect: WorkbenchTheme.risk
    }
  }

  private var externalConfirmationTitle: String {
    guard let step = externalConfirmationStep,
      let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command)
    else {
      return String(localized: "确认外部操作")
    }
    return String(
      format: String(localized: "确认“%@”？"),
      locale: .autoupdatingCurrent,
      descriptor.title
    )
  }

  private func confirmationTargetTitle(for step: WorkbenchAutomationStep) -> String {
    guard step.arguments.draftID == currentDraft.id else {
      return step.arguments.draftID?.uuidString ?? String(localized: "未知目标")
    }
    return currentDraft.title.nilIfEmpty ?? String(localized: "未命名文章")
  }

  private func externalConfirmationMessage(
    for step: WorkbenchAutomationStep,
    descriptor: WorkbenchAutomationCommandDescriptor
  ) -> String {
    if step.command == .publishOnline,
      let authorization = step.publishAuthorization
    {
      let scope = authorization.scope
      let files = scope.files.map { "- \($0.path)" }.joined(separator: "\n")
      return """
        站点：\(scope.siteName)
        仓库：\(scope.repositoryProviderDisplayName) · \(scope.repositoryDisplayName)
        目标分支：\(scope.targetBranch)
        发布模式：\(scope.publishModeDisplayName)
        完整文件范围（\(scope.files.count)）：
        \(files)

        执行前将重新计算并比对目标、路径、内容摘要和 Git 基线。任何变化都会拒绝发布并要求重新确认。
        """
    }
    return String(
      format: String(localized: "“%@”将作用于文章“%@”。软件只执行这一项，不会自动确认后续步骤。"),
      locale: .autoupdatingCurrent,
      descriptor.title,
      confirmationTargetTitle(for: step)
    )
  }

  private func confirmationButtonTitle(
    for step: WorkbenchAutomationStep,
    risk: WorkbenchAutomationRisk
  ) -> LocalizedStringKey {
    if step.command == .publishOnline,
      step.publishAuthorization == nil
    {
      return "审阅发布"
    }
    return risk == .contentChange ? "预览修改" : "确认执行"
  }

  @ViewBuilder
  private func publishAuthorizationScope(
    _ authorization: AIPublishAuthorizationSnapshot
  ) -> some View {
    let scope = authorization.scope
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: "站点：\(scope.siteName)")
      Text(
        verbatim:
          "目标：\(scope.repositoryProviderDisplayName) · \(scope.repositoryDisplayName) · \(scope.targetBranch)"
      )
      Text(verbatim: "模式：\(scope.publishModeDisplayName)")
      Text(verbatim: "完整文件范围（\(scope.files.count)）")
        .fontWeight(.semibold)
      ForEach(scope.files, id: \.path) { file in
        Text(verbatim: "• \(file.path)")
          .textSelection(.enabled)
      }
      Text(
        verbatim: "授权有效至：\(authorization.expiresAt.formatted(date: .abbreviated, time: .standard))")
    }
    .font(.workbenchMetadata)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.top, 3)
  }
}

private struct AutomationDraftPreviewItem: Identifiable {
  var id: UUID { stepID }
  let stepID: UUID
  let preview: WorkbenchAutomationDraftPreview
  let isAgentReview: Bool
}

private struct AutomationStepStatusIndicator: View {
  let status: WorkbenchAutomationStepStatus

  var body: some View {
    ZStack {
      Circle()
        .fill(stepStatusColor.opacity(status == .running ? 0.22 : 0.14))

      Image(systemName: stepStatusSystemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(stepStatusColor)
    }
    .frame(width: 25, height: 25)
  }

  private var stepStatusSystemImage: String {
    switch status {
    case .proposed: "circle"
    case .running: "hourglass"
    case .awaitingConfirmation: "hand.raised.fill"
    case .succeeded: "checkmark"
    case .failed: "xmark"
    case .cancelled: "slash"
    }
  }

  private var stepStatusColor: Color {
    switch status {
    case .succeeded: WorkbenchTheme.success
    case .failed: WorkbenchTheme.risk
    case .awaitingConfirmation: WorkbenchTheme.warning
    case .running, .proposed: WorkbenchTheme.primary
    case .cancelled: .secondary
    }
  }
}
