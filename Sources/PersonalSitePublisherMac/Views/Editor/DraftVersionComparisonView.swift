import PublishingWorkbenchCore
import SwiftUI

private enum DraftVersionComparisonTarget: Hashable {
  case current
  case version(UUID)
}

struct DraftVersionComparisonRequestKey: Hashable, Sendable {
  enum Target: Hashable, Sendable {
    case current(draftID: UUID, metadataRevision: UInt64, bodyRevision: UInt64)
    case version(UUID)
  }

  let sourceVersionID: UUID
  let target: Target
}

struct DraftVersionComparisonRequest: Sendable {
  let key: DraftVersionComparisonRequestKey
  let previous: ArticleDraft
  let current: ArticleDraft

  static func current(
    sourceVersion: DraftVersionSnapshot,
    targetDraft: ArticleDraft,
    bodyMarkdown: String,
    bodyRevision: UInt64
  ) -> Self {
    var frozenTarget = targetDraft
    frozenTarget.bodyMarkdown = bodyMarkdown
    return Self(
      key: DraftVersionComparisonRequestKey(
        sourceVersionID: sourceVersion.id,
        target: .current(
          draftID: targetDraft.id,
          metadataRevision: targetDraft.editorMetadataRevision,
          bodyRevision: bodyRevision
        )
      ),
      previous: sourceVersion.draft,
      current: frozenTarget
    )
  }

  static func version(
    sourceVersion: DraftVersionSnapshot,
    targetVersion: DraftVersionSnapshot
  ) -> Self {
    Self(
      key: DraftVersionComparisonRequestKey(
        sourceVersionID: sourceVersion.id,
        target: .version(targetVersion.id)
      ),
      previous: sourceVersion.draft,
      current: targetVersion.draft
    )
  }
}

@MainActor
final class DraftVersionComparisonLoader: ObservableObject {
  typealias Comparator = @Sendable (ArticleDraft, ArticleDraft) async -> DraftVersionComparison

  @Published private(set) var comparison: DraftVersionComparison?
  @Published private(set) var isLoading = false

  private let comparator: Comparator
  private var cache: [DraftVersionComparisonRequestKey: DraftVersionComparison] = [:]
  private var cacheOrder: [DraftVersionComparisonRequestKey] = []
  private let cacheLimit = 8
  private var inFlight: [DraftVersionComparisonRequestKey: Task<DraftVersionComparison, Never>] =
    [:]
  private var currentKey: DraftVersionComparisonRequestKey?
  private var generation: UInt64 = 0

  init(
    comparator: @escaping Comparator = { previous, current in
      await Task.detached(priority: .userInitiated) {
        DraftVersionComparisonService().compare(
          previous: previous, current: current, includeAlignedBodyRows: true)
      }.value
    }
  ) {
    self.comparator = comparator
  }

  func load(_ request: DraftVersionComparisonRequest?) async {
    generation &+= 1
    let requestedGeneration = generation
    currentKey = request?.key

    guard let request else {
      comparison = nil
      isLoading = false
      return
    }
    if let cached = cache[request.key] {
      markRecentlyUsed(request.key)
      comparison = cached
      isLoading = false
      return
    }

    comparison = nil
    isLoading = true
    let workTask: Task<DraftVersionComparison, Never>
    if let existing = inFlight[request.key] {
      workTask = existing
    } else {
      let comparator = comparator
      let previous = request.previous
      let current = request.current
      let created = Task {
        await comparator(previous, current)
      }
      inFlight[request.key] = created
      workTask = created
    }
    let result = await workTask.value
    inFlight[request.key] = nil
    cache[request.key] = result
    markRecentlyUsed(request.key)
    guard !Task.isCancelled,
      currentKey == request.key,
      generation == requestedGeneration
    else {
      return
    }
    comparison = result
    isLoading = false
  }

  // Aligned comparisons contain the full body, so retain only recent pairs.
  private func markRecentlyUsed(_ key: DraftVersionComparisonRequestKey) {
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    while cacheOrder.count > cacheLimit {
      cache.removeValue(forKey: cacheOrder.removeFirst())
    }
  }
}

struct DraftVersionComparisonView: View {
  let store: WorkbenchStore
  let sourceVersion: DraftVersionSnapshot
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @StateObject private var liveContext: WorkbenchMarkdownEditorLiveContextFeatureFacade
  @StateObject private var comparisonLoader: DraftVersionComparisonLoader
  @Environment(\.dismiss) private var dismiss
  @State private var sourceVersionID: UUID
  @State private var versions: [DraftVersionSnapshot]
  @State private var versionPendingRestoreID: UUID?
  @State private var target = DraftVersionComparisonTarget.current
  @State private var changesOnly = false
  @State private var isRestoreConfirmationPresented = false

  init(store: WorkbenchStore, sourceVersion: DraftVersionSnapshot) {
    self.store = store
    self.sourceVersion = sourceVersion
    _sourceVersionID = State(initialValue: sourceVersion.id)
    _versions = State(initialValue: store.versions(for: sourceVersion.draftID))
    _publishing = ObservedObject(wrappedValue: store.publishing)
    _liveContext = StateObject(
      wrappedValue: WorkbenchMarkdownEditorLiveContextFeatureFacade(
        store: store,
        draftID: sourceVersion.draftID
      )
    )
    _comparisonLoader = StateObject(wrappedValue: DraftVersionComparisonLoader())
  }

  private var selectedSourceVersion: DraftVersionSnapshot? {
    versions.first { $0.id == sourceVersionID }
  }

  private var currentDraft: ArticleDraft? {
    publishing.drafts.first { $0.id == sourceVersion.draftID }
  }

  private var comparisonRequest: DraftVersionComparisonRequest? {
    guard let selectedSourceVersion else { return nil }
    switch target {
    case .current:
      guard let currentDraft else { return nil }
      return .current(
        sourceVersion: selectedSourceVersion,
        targetDraft: currentDraft,
        bodyMarkdown: liveContext.bodyMarkdown,
        bodyRevision: liveContext.bodyRevision
      )
    case .version(let versionID):
      guard let targetVersion = versions.first(where: { $0.id == versionID }) else {
        return nil
      }
      return .version(sourceVersion: selectedSourceVersion, targetVersion: targetVersion)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      comparisonHeader
        .padding(WorkbenchSpacing.content)

      Divider()

      if comparisonLoader.isLoading {
        WorkbenchStateView(
          presentation: WorkbenchStatePresentation(
            kind: .loading(detail: String(localized: "正在计算版本差异…"))
          )
        )
      } else if let comparison = comparisonLoader.comparison {
        comparisonContent(comparison)
      } else {
        WorkbenchStateView(
          presentation: WorkbenchStatePresentation(
            kind: .unavailable(
              reason: String(localized: "当前文章或所选对比版本已不存在。")
            )
          )
        )
      }

      Divider()

      ViewThatFits(in: .horizontal) {
        HStack {
          restoreNotice
          Spacer(minLength: 12)
          restoreActions
        }
        VStack(alignment: .leading, spacing: 10) {
          restoreNotice
          restoreActions
        }
      }
      .padding(WorkbenchSpacing.content)
    }
    .frame(idealWidth: 980, minHeight: 420, idealHeight: 720)
    .navigationTitle("版本差异")
    .confirmationDialog(
      String(localized: "恢复左侧版本？"),
      isPresented: $isRestoreConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("恢复左侧版本", role: .destructive) {
        guard let versionID = versionPendingRestoreID,
          versions.contains(where: { $0.id == versionID }), currentDraft != nil
        else { return }
        if store.restoreDraftVersion(versionID) {
          dismiss()
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("恢复前会自动保存当前内容，因此仍可从版本历史回到恢复前状态。")
    }
    .onChange(of: sourceVersionID) { _, selectedID in
      if target == .version(selectedID) { target = .current }
    }
    .onReceive(publishing.draftVersionChanges) { snapshots in
      versions = snapshots.filter { $0.draftID == sourceVersion.draftID }
        .sorted { $0.capturedAt > $1.capturedAt }
    }
    .task(id: comparisonRequest?.key) {
      await comparisonLoader.load(comparisonRequest)
    }
    .accessibilityIdentifier("draft-version-comparison")
  }

  private var restoreNotice: some View {
    Text("恢复只替换文章内容；当前仓库路径、远端版本和发布状态会保留。")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var restoreActions: some View {
    HStack {
      Spacer(minLength: 0)
      Button("取消") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button {
        versionPendingRestoreID = selectedSourceVersion?.id
        isRestoreConfirmationPresented = true
      } label: {
        if let selectedSourceVersion {
          // swift-format-ignore
          Text("恢复左侧版本 · \(selectedSourceVersion.capturedAt.formatted(date: .abbreviated, time: .shortened))")
        } else {
          Text("恢复左侧版本")
        }
      }
      .workbenchProminentActionStyle()
      .keyboardShortcut(.defaultAction)
      .disabled(currentDraft == nil || selectedSourceVersion == nil)
    }
  }

  private var comparisonHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          sourcePicker
          targetPicker
        }
        VStack(alignment: .leading, spacing: 12) {
          sourcePicker
          targetPicker
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack {
          comparisonSummary
          Spacer(minLength: 12)
          changesOnlyToggle
        }
        VStack(alignment: .leading, spacing: 10) {
          comparisonSummary
          changesOnlyToggle
        }
      }
    }
  }

  private var sourcePicker: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("旧版（左侧）").font(.caption).foregroundStyle(.secondary)
      Picker("旧版（左侧）", selection: $sourceVersionID) {
        if selectedSourceVersion == nil {
          Text("所选版本已不存在。").tag(sourceVersionID)
        }
        ForEach(versions) { version in
          Text(versionMenuTitle(version)).tag(version.id)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier("draft-version-source-picker")
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var targetPicker: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("新版（右侧）").font(.caption).foregroundStyle(.secondary)
      Picker("新版（右侧）", selection: $target) {
        Text("当前文章").tag(DraftVersionComparisonTarget.current)
        if case .version(let versionID) = target,
          !versions.contains(where: { $0.id == versionID })
        {
          Text("所选版本已不存在。").tag(target)
        }
        ForEach(versions.filter { $0.id != sourceVersionID }) { version in
          Text(versionMenuTitle(version)).tag(DraftVersionComparisonTarget.version(version.id))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier("draft-version-target-picker")
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var changesOnlyToggle: some View {
    Toggle("只看改动", isOn: $changesOnly)
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("draft-version-changes-only")
  }

  @ViewBuilder
  private var comparisonSummary: some View {
    if let comparison = comparisonLoader.comparison {
      HStack(spacing: 8) {
        comparisonBadge("元数据 \(comparison.fieldChanges.count)", color: WorkbenchTheme.info)
        comparisonBadge("+\(comparison.addedLineCount)", color: WorkbenchTheme.success)
        comparisonBadge("−\(comparison.removedLineCount)", color: WorkbenchTheme.risk)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "元数据变化 \(comparison.fieldChanges.count) 项，新增 \(comparison.addedLineCount) 行，删除 \(comparison.removedLineCount) 行"
      )
    }
  }

  private func comparisonBadge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption.monospacedDigit().weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, WorkbenchSpacing.control)
      .padding(.vertical, WorkbenchSpacing.tight)
      .background(color.opacity(0.1), in: Capsule())
  }

  private func comparisonContent(_ comparison: DraftVersionComparison) -> some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          metadataChanges(comparison.fieldChanges)
          DraftVersionAlignedBodyView(
            rows: comparison.alignedBodyRows,
            changesOnly: changesOnly,
            availableWidth: max(0, geometry.size.width - 2 * WorkbenchSpacing.content)
          )
        }
        .padding(WorkbenchSpacing.content)
      }
      .accessibilityIdentifier("draft-version-synchronized-scroll")
    }
  }

  @ViewBuilder
  private func metadataChanges(_ changes: [DraftVersionFieldChange]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("元数据变化", systemImage: "list.bullet.rectangle")
        .font(.headline)

      if changes.isEmpty {
        Text("元数据没有变化")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(changes, id: \.field) { change in
          ViewThatFits(in: .horizontal) {
            metadataChangeRow(change)
            metadataChangeColumn(change)
          }
        }
      }
    }
  }

  private func metadataChangeRow(_ change: DraftVersionFieldChange) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(change.field.localizedDisplayName)
        .font(.subheadline.weight(.semibold))
        .frame(width: 84, alignment: .leading)
      comparisonValue(change.previousValue, color: WorkbenchTheme.risk)
      Image(systemName: "arrow.right")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      comparisonValue(change.currentValue, color: WorkbenchTheme.success)
    }
    .padding(WorkbenchSpacing.card)
    .background(
      .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func metadataChangeColumn(_ change: DraftVersionFieldChange) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(change.field.localizedDisplayName)
        .font(.subheadline.weight(.semibold))
      comparisonValue(change.previousValue, color: WorkbenchTheme.risk)
      Image(systemName: "arrow.down")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, alignment: .center)
      comparisonValue(change.currentValue, color: WorkbenchTheme.success)
    }
    .padding(WorkbenchSpacing.card)
    .background(
      .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func comparisonValue(_ value: String, color: Color) -> some View {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let isEmpty = trimmed.isEmpty
    return Text(isEmpty ? String(localized: "（空）") : value)
      .font(.callout)
      .foregroundStyle(isEmpty ? Color.secondary.opacity(0.6) : color)
      .italic(isEmpty)
      .textSelection(.enabled)
      .padding(.horizontal, WorkbenchSpacing.icon)
      .padding(.vertical, WorkbenchSpacing.tight)
      .background(
        isEmpty ? Color.clear : color.opacity(0.08),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func versionMenuTitle(_ version: DraftVersionSnapshot) -> String {
    "\(version.reason.localizedDisplayName) · \(version.capturedAt.formatted(date: .abbreviated, time: .standard))"
  }

}

extension DraftVersionEditableField {
  var localizedDisplayName: String {
    switch self {
    case .title: String(localized: "标题")
    case .date: String(localized: "日期")
    case .slug: String(localized: "Slug")
    case .tags: String(localized: "标签")
    case .categories: String(localized: "分类")
    case .authors: String(localized: "作者")
    case .aliases: String(localized: "旧地址别名")
    case .permalink: String(localized: "固定地址")
    case .translationKey: String(localized: "翻译关联键")
    case .draftState: String(localized: "草稿状态")
    case .visibility: String(localized: "可见性")
    case .summary: String(localized: "摘要")
    case .cover: String(localized: "封面")
    case .attachments: String(localized: "附件")
    }
  }
}
