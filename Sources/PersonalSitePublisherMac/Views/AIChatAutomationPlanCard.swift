import PublishingWorkbenchCore
import SwiftUI

struct AIChatAutomationPlanCard: View {
  let message: AIPublishingChatMessage
  let plan: WorkbenchAutomationPlan
  let currentDraft: ArticleDraft
  let isAutomationRunning: Bool
  let latestRunRecord: WorkbenchAutomationRunRecord?
  let actions: AIChatContextInspectorActions

  @State private var draftPreview: AutomationDraftPreviewItem?
  @State private var externalConfirmationStep: WorkbenchAutomationStep?

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
              actions.executeAutomationPlan(message.id)
            } label: {
              Label("执行安全步骤", systemImage: "play.fill")
            }
            .workbenchProminentActionStyle()
            .disabled(isAutomationRunning)
          }

          Button(role: .cancel) {
            actions.cancelAutomationPlan(message.id)
          } label: {
            Text("取消计划")
          }

          Spacer(minLength: 0)
        }
        .controlSize(.small)
      }

      if let latestRunRecord, latestRunRecord.hasRollback {
        Button {
          actions.rollbackAutomationRun(latestRunRecord.id)
        } label: {
          Label("撤销本次本地修改", systemImage: "arrow.uturn.backward")
        }
        .controlSize(.small)
        .disabled(isAutomationRunning)
      } else if latestRunRecord?.rolledBackAt != nil {
        Label("本次本地修改已撤销", systemImage: "arrow.uturn.backward.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
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
        )
      ) {
        actions.executeAutomationStep(message.id, item.stepID)
      }
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
          actions.executeAutomationStep(message.id, step.id)
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
  private func automationStepRow(index: Int, step: WorkbenchAutomationStep) -> some View {
    let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command)
    HStack(alignment: .top, spacing: 9) {
      ZStack {
        Circle()
          .fill(stepStatusColor(step.status).opacity(0.14))
        Image(systemName: stepStatusSystemImage(step.status))
          .font(.caption.weight(.semibold))
          .foregroundStyle(stepStatusColor(step.status))
      }
      .frame(width: 25, height: 25)

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
        .disabled(isAutomationRunning)
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
  }

  private func handleConfirmation(
    for step: WorkbenchAutomationStep,
    risk: WorkbenchAutomationRisk
  ) {
    if step.command == .publishOnline,
      step.publishAuthorization == nil
    {
      actions.executeAutomationStep(message.id, step.id)
    } else if risk == .contentChange {
      guard let preview = actions.previewAutomationStep(message.id, step.id) else { return }
      draftPreview = AutomationDraftPreviewItem(stepID: step.id, preview: preview)
    } else {
      externalConfirmationStep = step
    }
  }

  private func shouldOfferConfirmation(for step: WorkbenchAutomationStep) -> Bool {
    guard step.status == .proposed || step.status == .awaitingConfirmation else { return false }
    return plan.requiresConfirmation(for: step)
  }

  private var hasExecutableSafeSteps: Bool {
    plan.steps.contains { step in
      guard step.status == .proposed,
        WorkbenchAutomationRegistry.descriptor(for: step.command) != nil
      else { return false }
      return !plan.requiresConfirmation(for: step)
    }
  }

  private var showsPlanActions: Bool {
    plan.steps.contains { !$0.status.isTerminal }
  }

  private var statusTitle: LocalizedStringKey {
    switch plan.status {
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
    switch plan.status {
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
    switch plan.status {
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
}
