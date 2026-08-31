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
  private var inFlight: [DraftVersionComparisonRequestKey: Task<DraftVersionComparison, Never>] = [:]
  private var currentKey: DraftVersionComparisonRequestKey?
  private var generation: UInt64 = 0

  init(
    comparator: @escaping Comparator = { previous, current in
      await Task.detached(priority: .userInitiated) {
        DraftVersionComparisonService().compare(previous: previous, current: current)
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
    guard !Task.isCancelled,
      currentKey == request.key,
      generation == requestedGeneration
    else {
      return
    }
    comparison = result
    isLoading = false
  }
}

struct DraftVersionComparisonView: View {
  let store: WorkbenchStore
  let sourceVersion: DraftVersionSnapshot
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @StateObject private var liveContext: WorkbenchMarkdownEditorLiveContextFeatureFacade
  @StateObject private var comparisonLoader: DraftVersionComparisonLoader
  @Environment(\.dismiss) private var dismiss
  @State private var target = DraftVersionComparisonTarget.current
  @State private var isRestoreConfirmationPresented = false

  init(store: WorkbenchStore, sourceVersion: DraftVersionSnapshot) {
    self.store = store
    self.sourceVersion = sourceVersion
    _publishing = ObservedObject(wrappedValue: store.publishing)
    _liveContext = StateObject(
      wrappedValue: WorkbenchMarkdownEditorLiveContextFeatureFacade(
        store: store,
        draftID: sourceVersion.draftID
      )
    )
    _comparisonLoader = StateObject(wrappedValue: DraftVersionComparisonLoader())
  }

  private var versions: [DraftVersionSnapshot] {
    store.versions(for: sourceVersion.draftID)
  }

  private var currentDraft: ArticleDraft? {
    publishing.drafts.first { $0.id == sourceVersion.draftID }
  }

  private var comparisonRequest: DraftVersionComparisonRequest? {
    switch target {
    case .current:
      guard let currentDraft else { return nil }
      return .current(
        sourceVersion: sourceVersion,
        targetDraft: currentDraft,
        bodyMarkdown: liveContext.bodyMarkdown,
        bodyRevision: liveContext.bodyRevision
      )
    case .version(let versionID):
      guard let targetVersion = versions.first(where: { $0.id == versionID }) else {
        return nil
      }
      return .version(sourceVersion: sourceVersion, targetVersion: targetVersion)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      comparisonHeader
        .padding(16)

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

      HStack {
        Text("恢复只替换文章内容；当前仓库路径、远端版本和发布状态会保留。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button {
          isRestoreConfirmationPresented = true
        } label: {
          Text("恢复左侧版本 · \(sourceVersion.capturedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(currentDraft == nil)
      }
      .padding(16)
    }
    .frame(minWidth: 860, idealWidth: 980, minHeight: 640, idealHeight: 720)
    .navigationTitle("版本差异")
    .confirmationDialog(
      String(localized: "恢复左侧版本？"),
      isPresented: $isRestoreConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("恢复左侧版本", role: .destructive) {
        if store.restoreDraftVersion(sourceVersion.id) {
          dismiss()
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("恢复前会自动保存当前内容，因此仍可从版本历史回到恢复前状态。")
    }
    .task(id: comparisonRequest?.key) {
      await comparisonLoader.load(comparisonRequest)
    }
    .accessibilityIdentifier("draft-version-comparison")
  }

  private var comparisonHeader: some View {
    HStack(alignment: .center, spacing: 16) {
      versionLabel(
        title: "所选版本",
        reason: sourceVersion.reason.localizedDisplayName,
        date: sourceVersion.capturedAt
      )

      Image(systemName: "arrow.right")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text("对比目标")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("对比目标", selection: $target) {
          Text("当前文章").tag(DraftVersionComparisonTarget.current)
          ForEach(versions.filter { $0.id != sourceVersion.id }) { version in
            Text(versionMenuTitle(version))
              .tag(DraftVersionComparisonTarget.version(version.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 310, alignment: .leading)
      }

      Spacer()

      if let comparison = comparisonLoader.comparison {
        HStack(spacing: 8) {
          comparisonBadge("元数据 \(comparison.fieldChanges.count)", color: WorkbenchTheme.primary)
          comparisonBadge("+\(comparison.addedLineCount)", color: WorkbenchTheme.success)
          comparisonBadge("−\(comparison.removedLineCount)", color: WorkbenchTheme.risk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "元数据变化 \(comparison.fieldChanges.count) 项，新增 \(comparison.addedLineCount) 行，删除 \(comparison.removedLineCount) 行"
        )
      }
    }
  }

  private func versionLabel(title: String, reason: String, date: Date) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(reason)
        .font(.headline)
      Text(date.formatted(date: .abbreviated, time: .shortened))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func comparisonBadge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption.monospacedDigit().weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.1), in: Capsule())
  }

  @ViewBuilder
  private func comparisonContent(_ comparison: DraftVersionComparison) -> some View {
    if comparison.hasChanges {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          metadataChanges(comparison.fieldChanges)
          bodyChanges(comparison)
        }
        .padding(16)
      }
    } else {
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .success(
            detail: String(localized: "这两个版本没有正文或可恢复元数据差异。")
          )
        )
      )
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
          .padding(10)
          .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func comparisonValue(_ value: String, color: Color) -> some View {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let isEmpty = trimmed.isEmpty
    return Text(isEmpty ? String(localized: "（空）") : value)
      .font(.callout)
      .foregroundStyle(isEmpty ? Color.secondary.opacity(0.6) : color)
      .italic(isEmpty)
      .textSelection(.enabled)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        isEmpty ? Color.clear : color.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 5)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func bodyChanges(_ comparison: DraftVersionComparison) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("正文差异", systemImage: "doc.text.magnifyingglass")
          .font(.headline)
        Spacer()
        Text("红色为所选版本中被删除的行，绿色为对比目标新增的行。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if comparison.bodyLineDiffs.isEmpty {
        Text("正文没有变化")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(comparison.bodyLineDiffs) { line in
              DraftVersionLineDiffRow(line: line)
            }
          }
          .frame(minWidth: 810, alignment: .leading)
          .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.separator, lineWidth: 1)
        }
      }
    }
  }

  private func versionMenuTitle(_ version: DraftVersionSnapshot) -> String {
    "\(version.reason.localizedDisplayName) · \(version.capturedAt.formatted(date: .abbreviated, time: .shortened))"
  }

}

private struct DraftVersionLineDiffRow: View {
  let line: DraftVersionLineDiff

  var body: some View {
    if line.kind == .skipped {
      Text("省略 \(line.skippedLineCount) 行未变化内容")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35))
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        lineNumber(line.previousLineNumber)
        lineNumber(line.currentLineNumber)
        Text(verbatim: prefix)
          .foregroundStyle(foregroundColor)
          .frame(width: 22, alignment: .center)
        Text(verbatim: line.text.isEmpty ? " " : line.text)
          .font(.callout.monospaced())
          .foregroundStyle(foregroundColor)
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 2)
      .background(backgroundColor)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
    }
  }

  private func lineNumber(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.tertiary)
      .frame(width: 42, alignment: .trailing)
      .padding(.trailing, 7)
  }

  private var prefix: String {
    switch line.kind {
    case .removed: "−"
    case .added: "+"
    case .unchanged, .skipped: " "
    }
  }

  private var foregroundColor: Color {
    switch line.kind {
    case .removed: WorkbenchTheme.risk
    case .added: WorkbenchTheme.success
    case .unchanged, .skipped: .primary
    }
  }

  private var backgroundColor: Color {
    switch line.kind {
    case .removed: WorkbenchTheme.risk.opacity(0.1)
    case .added: WorkbenchTheme.success.opacity(0.1)
    case .unchanged, .skipped: .clear
    }
  }

  private var accessibilityLabel: String {
    switch line.kind {
    case .removed: "删除行 \(line.previousLineNumber ?? 0)：\(line.text)"
    case .added: "新增行 \(line.currentLineNumber ?? 0)：\(line.text)"
    case .unchanged: "未变化：\(line.text)"
    case .skipped: "省略 \(line.skippedLineCount) 行未变化内容"
    }
  }
}

private extension DraftVersionEditableField {
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
    case .draftState: String(localized: "草稿状态")
    case .visibility: String(localized: "可见性")
    case .summary: String(localized: "摘要")
    case .cover: String(localized: "封面")
    case .attachments: String(localized: "附件")
    }
  }
}
