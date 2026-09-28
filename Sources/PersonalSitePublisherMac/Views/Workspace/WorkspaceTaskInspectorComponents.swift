import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct InspectorScaffold<Content: View>: View {
  let title: String
  let subtitle: String
  let systemImage: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text(LocalizedStringKey(title))
            .font(.headline)
          Text(LocalizedStringKey(subtitle))
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        Spacer()
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
  }
}

struct TranslationRelationshipSection: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let link: AITranslationDraftLink

  var body: some View {
    let source = store.drafts.first(where: { $0.id == link.sourceDraftID })
    let sourceProfile = source.map { store.profile(for: $0) }
    let freshness = draft.translationFreshness(source: source, profile: sourceProfile)
    InspectorStatRow(
      title: String(localized: "关联译文"),
      value: "\(link.targetLanguageCode) · \(statusText(freshness))",
      systemImage: freshness == .current
        ? "globe" : "exclamationmark.arrow.triangle.2.circlepath"
    )
    if let source {
      Button {
        store.selectDraft(source.id)
      } label: {
        Label("查看原稿：\(source.title)", systemImage: "arrow.up.left")
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("metadata-open-translation-source")
      if freshness == .stale {
        Button {
          var reviewed = draft
          let currentSource = store.drafts.first(where: { $0.id == link.sourceDraftID })
          let currentProfile = currentSource.map { store.profile(for: $0) }
          if reviewed.markTranslationReviewed(source: currentSource, profile: currentProfile) {
            store.updateDraftFromEditor(reviewed)
          }
        } label: {
          Label("已核对，标记为最新", systemImage: "checkmark.circle")
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("metadata-mark-translation-current")
      }
    }
  }

  private func statusText(_ freshness: ArticleTranslationFreshness?) -> String {
    switch freshness {
    case .current: return String(localized: "与原稿一致")
    case .stale: return String(localized: "原稿已变化，译文待核对")
    case .sourceMissing: return String(localized: "找不到原稿")
    case .none: return String(localized: "状态未知")
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(LocalizedStringKey(title))
        .font(.workbenchCardTitle)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

struct InspectorDisclosureSection<Content: View>: View {
  let title: String
  let detail: String?
  @Binding var isExpanded: Bool
  @ViewBuilder var content: Content

  init(
    _ title: String,
    detail: String? = nil,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 9) {
        content
      }
      .padding(.top, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 8) {
        Text(LocalizedStringKey(title))
          .font(.workbenchCardTitle)
        Spacer(minLength: 8)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.workbenchMetadata.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

struct InspectorStatRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .workbenchTruncatedIdentity(value)
    }
    .font(.workbenchSupporting)
  }
}

struct WorkspaceTaskInspectorSocialImagePresentation: Equatable {
  let value: String
  let warning: String?
}

enum WorkspaceTaskInspectorPresentation {
  static func summaryAIUnavailableReason(
    availability: AIPublishingActionAvailabilityPresentation,
    requiresAPIKey: Bool,
    hasAPIKey: Bool
  ) -> String? {
    guard !availability.isEnabled else { return nil }
    if requiresAPIKey && !hasAPIKey {
      return String(localized: "未配置 API Key")
    }
    return availability.unavailableReason
  }

  static func seoCharacterCountText(_ count: Int) -> String {
    "\(count) \(String(localized: "字符"))"
  }

  static func socialImagePresentation(
    imagePath: String?,
    imageDimensions: ImageDimensions?
  ) -> WorkspaceTaskInspectorSocialImagePresentation {
    let value =
      imageDimensions?.workbenchDimensionText
      ?? (imagePath == nil ? String(localized: "未设置") : String(localized: "已设置"))
    let warning: String?
    if let imageDimensions,
      imageDimensions.width < 1200 || imageDimensions.height < 630
    {
      warning = String(localized: "尺寸偏小，建议至少 1200×630")
    } else {
      warning = nil
    }
    return WorkspaceTaskInspectorSocialImagePresentation(value: value, warning: warning)
  }
}

@ViewBuilder
func actionMessage(_ message: String?) -> some View {
  if let message, !message.isEmpty {
    Text(message)
      .font(.workbenchSupporting)
      .foregroundStyle(.secondary)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }
}

extension PublishFileDiffStatus {
  var systemImage: String {
    switch self {
    case .added:
      return "plus.circle"
    case .modified:
      return "pencil.circle"
    case .deleted:
      return "trash.circle"
    case .unchanged:
      return "equal.circle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    case .unsafePath:
      return "xmark.octagon"
    }
  }

  var color: Color {
    switch self {
    case .added:
      return WorkbenchTheme.success
    case .modified:
      return WorkbenchTheme.warning
    case .deleted:
      return WorkbenchTheme.risk
    case .unchanged:
      return .secondary
    case .missingSource, .unsafePath:
      return WorkbenchTheme.risk
    }
  }
}

/// Window-local state for the checks tab; kept here with inspector components
/// so the section view can redraw without rebuilding a preflight result.
@MainActor
final class ArticleInspectorPreflightModel: ObservableObject {
  typealias Debounce = @Sendable (Duration) async throws -> Void

  enum State: Equatable {
    case idle
    case loading
    case available
    case unavailable
  }

  @Published private(set) var requestKey: DraftScopedPreflightRequestKey?
  @Published private(set) var result: DraftPreflightResult?
  @Published private(set) var state: State = .idle

  private var generation = 0
  private let debounce: Debounce

  init(
    clock: any Clock<Duration> = ContinuousClock(),
    debounce: Debounce? = nil
  ) {
    self.debounce = debounce ?? { duration in try await clock.sleep(for: duration) }
  }

  func refresh(
    requestKey: DraftScopedPreflightRequestKey,
    draftID: UUID,
    debounceDuration: Duration? = nil,
    loader: @escaping @MainActor () async -> DraftPreflightResult?
  ) async {
    generation += 1
    let refreshGeneration = generation
    self.requestKey = requestKey
    state = .loading

    if let debounceDuration {
      do {
        try await debounce(debounceDuration)
        try Task.checkCancellation()
      } catch {
        return
      }
    }

    let loadedResult = await loader()
    guard !Task.isCancelled,
      generation == refreshGeneration,
      self.requestKey == requestKey
    else {
      return
    }

    guard let loadedResult, loadedResult.context.draftID == draftID else {
      state = .unavailable
      return
    }
    result = loadedResult
    state = .available
  }
}
