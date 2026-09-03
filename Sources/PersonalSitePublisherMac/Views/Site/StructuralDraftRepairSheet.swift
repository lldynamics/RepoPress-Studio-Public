import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct StructuralDraftRepairSheet: View {
  @Environment(\.dismiss) private var dismiss

  let rescan: () async throws -> StructuralDraftRepairPreview
  let apply:
    (StructuralDraftRepairPreview, Set<UUID>, Set<String>) async throws
      -> StructuralDraftRepairResult
  let onRepairCompleted: () -> Void
  let onShowRepairedDrafts: (([UUID]) -> Void)?
  let onRecheck: (() -> Void)?
  let onPreparePublishing: (() -> Void)?

  @State private var preview: StructuralDraftRepairPreview
  @State private var selection = StructuralDraftRepairSelection.empty
  @State private var step: StructuralDraftRepairStep = .preserveContent
  @State private var isRescanning = false
  @State private var isApplying = false
  @State private var isConfirmationPresented = false
  @State private var operationError: String?
  @State private var requiresRescan = false
  @State private var result: StructuralDraftRepairResult?

  init(
    preview: StructuralDraftRepairPreview,
    rescan: @escaping () async throws -> StructuralDraftRepairPreview,
    apply:
      @escaping (StructuralDraftRepairPreview, Set<UUID>, Set<String>) async throws
      -> StructuralDraftRepairResult,
    onRepairCompleted: @escaping () -> Void,
    onShowRepairedDrafts: (([UUID]) -> Void)? = nil,
    onRecheck: (() -> Void)? = nil,
    onPreparePublishing: (() -> Void)? = nil
  ) {
    _preview = State(initialValue: preview)
    self.rescan = rescan
    self.apply = apply
    self.onRepairCompleted = onRepairCompleted
    self.onShowRepairedDrafts = onShowRepairedDrafts
    self.onRecheck = onRecheck
    self.onPreparePublishing = onPreparePublishing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      stepNavigation

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if !preview.warnings.isEmpty {
            AccessibleStatusMessage(
              message: preview.warnings.joined(separator: "\n"),
              severity: .warning
            )
          }

          stepContent
          operationStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      footer
    }
    .padding(20)
    .frame(minWidth: 620, idealWidth: 760, minHeight: 540, idealHeight: 680)
    .alert("确认备份并修复？", isPresented: $isConfirmationPresented) {
      Button("取消", role: .cancel) {}
      Button("备份并修复") {
        applySelectedRepairs()
      }
      .keyboardShortcut(.defaultAction)
    } message: {
      Text(confirmationSummary)
    }
    .interactiveDismissDisabled(isApplying)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("遗留目录修复")
    .accessibilityIdentifier("structural-draft-repair-sheet")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Label("修复遗留目录记录", systemImage: "wrench.and.screwdriver")
        .font(.title3.weight(.semibold))
      Spacer()
      Button("重新扫描", systemImage: "arrow.clockwise") {
        rescanPreview()
      }
      .disabled(isRescanning || isApplying || result != nil)
      .accessibilityIdentifier("structural-draft-repair-rescan")

      Button("关闭") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .disabled(isApplying)
      .accessibilityIdentifier("structural-draft-repair-close")
    }
  }

  private var stepNavigation: some View {
    HStack(spacing: 8) {
      ForEach(StructuralDraftRepairStep.allCases) { candidate in
        Label(candidate.title, systemImage: step == candidate ? "circle.inset.filled" : "circle")
          .font(.caption.weight(step == candidate ? .semibold : .regular))
          .foregroundStyle(step == candidate ? WorkbenchTheme.navigationSelection : .secondary)
          .accessibilityAddTraits(step == candidate ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("修复步骤")
    .accessibilityValue(step.title)
  }

  @ViewBuilder
  private var stepContent: some View {
    switch step {
    case .preserveContent:
      preserveContentStep
    case .restoreFiles:
      restoreFilesStep
    case .confirm:
      confirmationStep
    }
  }

  private var preserveContentStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("第 1 步：保留旧内容", systemImage: "doc.text")
        .font(.headline)
      Text("所选记录会从站点栏目绑定转为素材库草稿；正文、附件和已有内容都会保留。此操作不会删除、下线或发布文章。")
        .font(.callout)
      Text("以下记录按站点栏目路径归组。每组默认均不选中；可按组全选或取消。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if draftGroups.isEmpty {
        Text("没有发现需要迁移为素材库的遗留目录记录。")
          .foregroundStyle(.secondary)
      } else {
        ForEach(draftGroups) { group in
          draftGroupSection(group)
        }
      }
    }
  }

  private func draftGroupSection(_ group: StructuralDraftRepairDraftGroup) -> some View {
    let selectedCount = group.records.filter { selection.draftIDs.contains($0.id) }.count
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(group.repositoryPath)
          .font(.callout.monospaced())
          .textSelection(.enabled)
        Text(String(localized: "\(group.records.count) 条记录"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(String(localized: "\(selectedCount) 已选"))
          .font(.caption)
          .foregroundStyle(selectedCount > 0 ? WorkbenchTheme.navigationSelection : .secondary)
        Spacer()
        Button(groupIsFullySelected(group) ? "取消本组" : "全选本组") {
          setGroup(group, isSelected: !groupIsFullySelected(group))
        }
        .disabled(isOperationComplete)
        .accessibilityIdentifier(
          "structural-draft-repair-toggle-group-\(accessibilityToken(for: group.repositoryPath))"
        )
      }

      DisclosureGroup("查看记录") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(group.records) { record in
            Toggle(isOn: draftSelectionBinding(for: record.id)) {
              Text(record.title)
            }
            .disabled(isOperationComplete)
            .accessibilityIdentifier("structural-draft-repair-draft-\(record.id.uuidString)")
          }
        }
      }
    }
    .padding(10)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  @ViewBuilder
  private var restoreFilesStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("第 2 步：可选恢复栏目文件", systemImage: "arrow.uturn.backward")
        .font(.headline)
      Text("文件恢复完全可跳过，默认不选中。基线来自扫描时固定的 Git 提交；该提交不保证就是正确版本，请审阅完整差异。修复后仍需单独本地构建和发布。")
        .font(.caption)
        .foregroundStyle(.secondary)
      LabeledContent("Git 基线") {
        Text(preview.sourceCommit ?? "未提供")
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      if preview.files.isEmpty {
        Text("没有可恢复的栏目文件；可直接进入确认步骤。")
          .foregroundStyle(.secondary)
      } else {
        ForEach(preview.files) { item in
          fileRecoveryRow(item)
        }
      }
    }
  }

  private func fileRecoveryRow(_ item: StructuralFileRepairItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: fileSelectionBinding(for: item.repositoryPath)) {
        HStack(spacing: 6) {
          Text(item.repositoryPath)
            .font(.callout.monospaced())
            .textSelection(.enabled)
          if item.wasMissing {
            Text("当前缺失")
              .font(.caption.weight(.semibold))
              .foregroundStyle(WorkbenchTheme.warning)
          }
        }
      }
      .disabled(isOperationComplete)
      .accessibilityIdentifier(
        "structural-draft-repair-file-\(accessibilityToken(for: item.repositoryPath))"
      )

      DisclosureGroup("查看完整差异") {
        Text(item.diff.nilIfEmpty ?? "没有可显示的文本差异。")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(10)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private var confirmationStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("第 3 步：确认并修复", systemImage: "checklist")
        .font(.headline)
      Text("实际修复只会在下方再次明确确认后执行。步骤回退不会丢失当前选择。")
        .font(.callout)
      LabeledContent("保留为素材库草稿") {
        Text(String(localized: "\(selection.draftIDs.count) 条"))
      }
      LabeledContent("恢复栏目文件") {
        Text(String(localized: "\(selection.paths.count) 个"))
      }
      Text(confirmationGuidance)
        .font(.caption)
        .foregroundStyle(
          selection.canApply && !requiresRescan ? .secondary : WorkbenchTheme.warning)

      if selection.canApply {
        DisclosureGroup("复核本次选择") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(preview.drafts.filter { selection.draftIDs.contains($0.id) }) { item in
              Text("草稿：\(item.title) · \(item.repositoryPath)")
                .font(.caption)
                .textSelection(.enabled)
            }
            ForEach(preview.files.filter { selection.paths.contains($0.repositoryPath) }) { item in
              Text("文件：\(item.repositoryPath)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(12)
    .background(
      WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  @ViewBuilder
  private var operationStatus: some View {
    if isRescanning {
      ProgressView("正在重新扫描遗留记录…")
        .accessibilityIdentifier("structural-draft-repair-rescan-progress")
    }
    if isApplying {
      ProgressView("正在备份并修复所选内容…")
        .accessibilityIdentifier("structural-draft-repair-apply-progress")
    }
    if let operationError {
      AccessibleStatusMessage(message: operationError, severity: .error)
        .textSelection(.enabled)
        .accessibilityIdentifier("structural-draft-repair-error")
    }
    if let result {
      resultSection(result)
    }
  }

  private func resultSection(_ result: StructuralDraftRepairResult) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      AccessibleStatusMessage(
        message: resultMessage(result),
        severity: result.fileRecoveryError == nil ? .success : .warning
      )

      LabeledContent("备份位置") {
        Text(result.backupURL.path)
          .font(.caption.monospaced())
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      Button("在 Finder 中显示备份", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([result.backupURL])
      }
      .accessibilityIdentifier("structural-draft-repair-reveal-backup")

      if !result.restoredPaths.isEmpty {
        Text(String(localized: "已恢复：\(result.restoredPaths.joined(separator: "、"))"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let fileRecoveryError = result.fileRecoveryError {
        AccessibleStatusMessage(message: fileRecoveryError, severity: .warning)
          .textSelection(.enabled)
      }

      resultFollowUpActions(result)
    }
    .padding(12)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  @ViewBuilder
  private func resultFollowUpActions(_ result: StructuralDraftRepairResult) -> some View {
    HStack(spacing: 8) {
      if let onShowRepairedDrafts, !selection.draftIDs.isEmpty {
        Button("查看已修复草稿", systemImage: "doc.text") {
          let repairedDraftIDs = selectedDraftIDsInPreviewOrder
          dismissThen { onShowRepairedDrafts(repairedDraftIDs) }
        }
        .accessibilityIdentifier("structural-draft-repair-show-drafts")
      }
      if let onRecheck {
        Button("重新检查", systemImage: "arrow.clockwise") {
          dismissThen(onRecheck)
        }
        .accessibilityIdentifier("structural-draft-repair-recheck")
      }
      if let onPreparePublishing, result.fileRecoveryError == nil {
        Button("准备发布", systemImage: "arrow.up.circle") {
          dismissThen(onPreparePublishing)
        }
        .accessibilityIdentifier("structural-draft-repair-prepare-publishing")
      }
    }
    .buttonStyle(.bordered)
  }

  private var footer: some View {
    HStack {
      Text(selectionSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("上一步") {
        moveToPreviousStep()
      }
      .disabled(step.previous == nil || isOperationComplete)
      .accessibilityIdentifier("structural-draft-repair-back")

      if step == .confirm {
        Button {
          isConfirmationPresented = true
        } label: {
          Label("备份并修复所选", systemImage: "externaldrive.badge.checkmark")
        }
        .workbenchProminentActionStyle()
        .disabled(!canApply)
        .accessibilityIdentifier("structural-draft-repair-confirm")
      } else {
        Button("下一步") {
          moveToNextStep()
        }
        .workbenchProminentActionStyle()
        .disabled(!canAdvance)
        .accessibilityIdentifier("structural-draft-repair-next")
      }
    }
  }

  private var draftGroups: [StructuralDraftRepairDraftGroup] {
    StructuralDraftRepairPresentation.groups(
      for: preview.drafts.map {
        StructuralDraftRepairDraftRecord(
          id: $0.id,
          title: $0.title,
          repositoryPath: $0.repositoryPath
        )
      })
  }

  private var canAdvance: Bool {
    StructuralDraftRepairPresentation.canAdvance(from: step, selection: selection)
      && !isOperationComplete
  }

  private var canApply: Bool {
    step == .confirm && selection.canApply && !requiresRescan && !isOperationComplete
  }

  private var isOperationComplete: Bool {
    isRescanning || isApplying || result != nil
  }

  private var selectionSummary: String {
    String(localized: "已选 \(selection.draftIDs.count) 条记录，\(selection.paths.count) 个文件。")
  }

  private var selectedDraftIDsInPreviewOrder: [UUID] {
    preview.drafts.compactMap { item in
      selection.draftIDs.contains(item.id) ? item.id : nil
    }
  }

  private var confirmationSummary: String {
    String(
      localized:
        "将先创建备份，再将 \(selection.draftIDs.count) 条记录转为素材库草稿，并尝试恢复 \(selection.paths.count) 个已选文件。不会发布、下线或删除文章。文件恢复失败时，工作台记录修复仍会保留。"
    )
  }

  private var confirmationGuidance: String {
    if requiresRescan {
      return String(localized: "预览已过期；请重新扫描后再确认，当前不会执行修复。")
    }
    if selection.canApply {
      return String(localized: "会先创建备份，再保存工作台记录；文件恢复失败时，记录修复仍会保留并单独报告。")
    }
    return String(localized: "请返回前两步，至少选择一条记录或一个文件。")
  }

  private func resultMessage(_ result: StructuralDraftRepairResult) -> String {
    if result.fileRecoveryError == nil {
      return String(
        localized:
          "已备份并修复 \(result.repairedDraftCount) 条工作台记录；恢复 \(result.restoredPaths.count) 个文件。"
      )
    }
    return String(localized: "工作台记录已保存，栏目文件恢复未全部完成。")
  }

  private func draftSelectionBinding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { selection.draftIDs.contains(id) },
      set: { isSelected in
        if isSelected {
          selection.draftIDs.insert(id)
        } else {
          selection.draftIDs.remove(id)
        }
      }
    )
  }

  private func fileSelectionBinding(for path: String) -> Binding<Bool> {
    Binding(
      get: { selection.paths.contains(path) },
      set: { isSelected in
        if isSelected {
          selection.paths.insert(path)
        } else {
          selection.paths.remove(path)
        }
      }
    )
  }

  private func groupIsFullySelected(_ group: StructuralDraftRepairDraftGroup) -> Bool {
    Set(group.records.map(\.id)).isSubset(of: selection.draftIDs)
  }

  private func setGroup(_ group: StructuralDraftRepairDraftGroup, isSelected: Bool) {
    let ids = Set(group.records.map(\.id))
    if isSelected {
      selection.draftIDs.formUnion(ids)
    } else {
      selection.draftIDs.subtract(ids)
    }
  }

  private func moveToNextStep() {
    guard canAdvance, let nextStep = StructuralDraftRepairPresentation.nextStep(after: step) else {
      return
    }
    step = nextStep
  }

  private func moveToPreviousStep() {
    guard !isOperationComplete,
      let previousStep = StructuralDraftRepairPresentation.previousStep(before: step)
    else { return }
    step = previousStep
  }

  private func accessibilityToken(for value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "\(value.utf8.count)-\(String(hash, radix: 16))"
  }

  private func rescanPreview() {
    guard !isOperationComplete else { return }
    isRescanning = true
    operationError = nil
    Task { @MainActor in
      defer { isRescanning = false }
      do {
        preview = try await rescan()
        selection = .empty
        step = .preserveContent
        requiresRescan = false
      } catch is CancellationError {
        return
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func applySelectedRepairs() {
    guard canApply else { return }
    isApplying = true
    operationError = nil
    Task { @MainActor in
      defer { isApplying = false }
      do {
        result = try await apply(preview, selection.draftIDs, selection.paths)
        onRepairCompleted()
      } catch is CancellationError {
        return
      } catch StructuralDraftRepairError.stalePreview {
        requiresRescan = true
        operationError = StructuralDraftRepairError.stalePreview.localizedDescription
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func dismissThen(_ action: @escaping () -> Void) {
    // Queue the requested destination before dismissal; the window host
    // performs navigation from onDismiss, after the native sheet has closed.
    action()
    dismiss()
  }
}
