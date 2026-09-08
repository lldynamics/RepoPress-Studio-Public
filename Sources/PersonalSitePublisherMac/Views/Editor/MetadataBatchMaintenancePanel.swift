import PublishingWorkbenchCore
import SwiftUI

struct MetadataBatchMaintenancePanel: View {
  @Environment(\.dismiss) private var dismiss
  let store: WorkbenchStore
  let initialDraftIDs: Set<UUID>
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @State private var field: MetadataBatchMaintenanceField = .tags
  @State private var operationKind: OperationKind = .add
  @State private var sourceValue = ""
  @State private var destinationValue = ""
  @State private var plan: MetadataBatchMaintenancePlan?
  @State private var selectedDraftIDs = Set<UUID>()
  @State private var message: String?
  @State private var isFailure = false

  private enum OperationKind: String, CaseIterable, Hashable, Identifiable {
    case add
    case remove
    case rename

    var id: String { rawValue }
    var title: String {
      switch self {
      case .add: String(localized: "添加")
      case .remove: String(localized: "移除")
      case .rename: String(localized: "重命名或合并")
      }
    }
  }

  init(store: WorkbenchStore, initialDraftIDs: Set<UUID>) {
    self.store = store
    self.initialDraftIDs = initialDraftIDs
    _publishing = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        controls
        Divider()
        previews
        Divider()
        footer
      }
      .navigationTitle(String(localized: "批量维护标签与分类"))
    }
    .frame(minWidth: 720, idealWidth: 820, minHeight: 510, idealHeight: 620)
    .onChange(of: field) { _, _ in invalidatePlan() }
    .onChange(of: operationKind) { _, _ in invalidatePlan() }
    .onChange(of: sourceValue) { _, _ in invalidatePlan() }
    .onChange(of: destinationValue) { _, _ in invalidatePlan() }
    .accessibilityIdentifier("metadata-batch-maintenance-panel")
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(String(localized: "字段"), selection: $field) {
        ForEach(MetadataBatchMaintenanceField.allCases, id: \.self) { field in
          Text(field.localizedTitle).tag(field)
        }
      }
      .pickerStyle(.segmented)

      Picker(String(localized: "操作"), selection: $operationKind) {
        ForEach(OperationKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)

      HStack(spacing: 10) {
        if operationKind != .add {
          TextField(
            operationKind == .rename
              ? String(localized: "原标签或分类")
              : String(localized: "要移除的标签或分类"),
            text: $sourceValue
          )
          .accessibilityLabel(String(localized: "原标签或分类"))
        }
        if operationKind != .remove {
          TextField(
            operationKind == .rename
              ? String(localized: "新标签或分类（已有值会合并）")
              : String(localized: "要添加的标签或分类"),
            text: $destinationValue
          )
          .accessibilityLabel(String(localized: "新标签或分类（已有值会合并）"))
        }
        Button(String(localized: "生成逐篇预览"), action: generatePlan)
          .workbenchProminentActionStyle()
          .disabled(!hasValidInput)
      }
      Text(String(localized: "预览会冻结生成时的目标字段；应用前将逐篇复验该字段，发生变化时必须重新预览。正文和其它 Front Matter 字段不会写入。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
  }

  @ViewBuilder
  private var previews: some View {
    if let plan {
      if plan.applicablePreviews.isEmpty {
        ContentUnavailableView(
          String(localized: "没有需要修改的文章"),
          systemImage: "checkmark.circle",
          description: Text(String(localized: "所选文章中没有匹配的目标字段。"))
        )
      } else {
        List(plan.applicablePreviews) { preview in
          HStack(alignment: .top, spacing: 10) {
            Toggle(
              isOn: Binding(
                get: { selectedDraftIDs.contains(preview.documentID) },
                set: { isSelected in
                  if isSelected {
                    selectedDraftIDs.insert(preview.documentID)
                  } else {
                    selectedDraftIDs.remove(preview.documentID)
                  }
                }
              )
            ) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(preview.title)

            VStack(alignment: .leading, spacing: 6) {
              Text(preview.title.nilIfEmpty ?? String(localized: "未命名文章"))
                .font(.headline)
              HStack(alignment: .top, spacing: 8) {
                metadataValueColumn(title: String(localized: "原值"), values: preview.originalValues)
                Image(systemName: "arrow.right")
                  .foregroundStyle(.secondary)
                  .padding(.top, 20)
                metadataValueColumn(title: String(localized: "建议值"), values: preview.proposedValues)
              }
            }
          }
          .padding(.vertical, 4)
        }
        .listStyle(.inset)
      }
    } else {
      ContentUnavailableView(
        String(localized: "先生成预览"),
        systemImage: "eye",
        description: Text(String(localized: "不会直接写入文章；请先确认逐篇变化。"))
      )
    }
  }

  private func metadataValueColumn(title: String, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(values.isEmpty ? String(localized: "（空）") : values.joined(separator: "、"))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 6))
  }

  private var footer: some View {
    HStack {
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(isFailure ? WorkbenchTheme.risk : WorkbenchTheme.success)
          .accessibilityLabel(message)
      }
      Spacer()
      Button(String(localized: "关闭"), action: dismiss.callAsFunction)
      Button(String(localized: "应用已选变化"), action: applyPlan)
        .workbenchProminentActionStyle()
        .disabled(plan == nil || selectedDraftIDs.isEmpty)
        .accessibilityIdentifier("metadata-batch-maintenance-apply")
    }
    .padding(16)
  }

  private var hasValidInput: Bool {
    switch operationKind {
    case .add: !destinationValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .remove: !sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .rename:
      !sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !destinationValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var operation: MetadataBatchMaintenanceOperation {
    switch operationKind {
    case .add: .add(destinationValue)
    case .remove: .remove(sourceValue)
    case .rename: .rename(source: sourceValue, destination: destinationValue)
    }
  }

  private func generatePlan() {
    let selected = publishing.drafts.filter { initialDraftIDs.contains($0.id) }
    let nextPlan = MetadataBatchMaintenanceService().plan(
      drafts: selected,
      field: field,
      operation: operation
    )
    plan = nextPlan
    selectedDraftIDs = Set(nextPlan.applicablePreviews.map(\.documentID))
    message = nil
  }

  private func invalidatePlan() {
    plan = nil
    selectedDraftIDs = []
    message = nil
  }

  private func applyPlan() {
    guard let plan else { return }
    switch store.applyMetadataBatchMaintenance(plan, selectedDraftIDs: selectedDraftIDs) {
    case .applied(let changedCount, let versionCount):
      message = String(
        format: String(localized: "已更新 %d 篇文章，并保存 %d 个恢复版本。"),
        changedCount,
        versionCount
      )
      isFailure = false
    case .conflicts(let ids):
      message = String(format: String(localized: "%d 篇文章的目标字段已变化，未写入任何文章；请重新预览。"), ids.count)
      isFailure = true
    case .unavailable(let ids):
      message = String(format: String(localized: "%d 篇文章已不存在或无权访问，未写入任何文章。"), ids.count)
      isFailure = true
    case .preflightPersistenceFailed:
      message = String(localized: "保存失败，未写入元数据或创建恢复版本；请检查存储和文章文件状态后重新预览。")
      isFailure = true
    case .recoveryVersionPersistenceFailed:
      message = String(localized: "恢复版本保存失败，未写入元数据；请检查存储后重新预览。")
      isFailure = true
    case .insufficientRecoveryVersions:
      message = String(localized: "恢复版本未覆盖全部文章，未应用修改；请减少本次选择的文章数量。")
      isFailure = true
    case .persistenceFailed(let recoveryVersionCount):
      message = String(
        format: String(localized: "保存失败，已保留 %d 个恢复版本；部分文章文件可能已保存。请通过版本恢复检查后重新预览。"),
        recoveryVersionCount
      )
      isFailure = true
    case .noChanges:
      message = String(localized: "没有可应用的变化。")
      isFailure = true
    }
  }
}
