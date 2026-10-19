import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct ArticlePublicationStatusView: View {
  private struct SourceInput: Hashable, Sendable {
    let draft: ArticleDraft
    let profile: SiteProfile

    var digest: String {
      draft.renderedRepositoryContentDigest(profile: profile)
    }
  }

  private struct ResolvedSource: Equatable {
    let input: SourceInput
    let digest: String
  }

  let store: WorkbenchStore
  let selectedDraftID: UUID?
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  // The status facade deliberately omits editor buffers. Observe them only
  // inside this small status view so unsaved edits immediately lose old proof.
  @ObservedObject private var articleState: WorkbenchPublishingFeatureFacade
  @State private var resolvedSource: ResolvedSource?

  init(store: WorkbenchStore, selectedDraftID: UUID?) {
    self.store = store
    self.selectedDraftID = selectedDraftID
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    _articleState = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: ArticlePublishTrackingRequest.checkInterval)) {
      context in
      statusContent(now: context.date)
    }
  }

  @ViewBuilder
  private func statusContent(now: Date) -> some View {
    if let input = sourceInput {
      let presentation = ArticlePublicationStatusPresentation.make(
        draft: input.draft,
        profile: input.profile,
        currentSourceDigest: currentDigest(for: input),
        records: store.releaseRecords,
        snapshots: store.deploymentStatusSnapshots,
        now: now
      )
      HStack(spacing: WorkbenchSpacing.tight) {
        Label(presentation.title, systemImage: systemImage(for: presentation.stage))
          .labelStyle(.titleAndIcon)
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(color(for: presentation.stage))
          .lineLimit(1)
          .accessibilityIdentifier("article-publication-status")

        if let verifiedAt = presentation.verifiedAt {
          Label(verifiedAt.workbenchShortText, systemImage: "clock")
            .labelStyle(.titleOnly)
            .font(.workbenchMetadata.monospacedDigit())
            .foregroundStyle(.workbenchSecondary)
            .lineLimit(1)
        }

        if let onlineURL = presentation.onlineURL {
          Link(destination: onlineURL) {
            Image(systemName: "arrow.up.right.square")
          }
          .help(String(localized: "打开已核验文章"))
          .accessibilityLabel(String(localized: "打开已核验文章"))
          .accessibilityIdentifier("article-publication-status-open-online")
        }
      }
      .padding(.horizontal, WorkbenchSpacing.tight)
      .padding(.vertical, WorkbenchSpacing.tight / 2)
      .background(.quaternary, in: Capsule())
      .help(presentation.detail)
      .accessibilityElement(children: .contain)
      // Recreate only the toolbar content when its meaning changes; AppKit
      // otherwise retains an earlier status as the native item's AX name.
      .id("\(input.draft.id)-\(presentation.title)")
      .task(id: input) {
        guard resolvedSource?.input != input else { return }
        let digest = await Task.detached(priority: .utility) { input.digest }.value
        guard !Task.isCancelled else { return }
        resolvedSource = ResolvedSource(input: input, digest: digest)
      }
    }
  }

  private var sourceInput: SourceInput? {
    guard let selectedDraftID,
      var draft = store.draft(for: selectedDraftID),
      !draft.isGeneralDraft,
      let profile = store.profiles.first(where: { $0.id == draft.siteProfileID })
    else { return nil }
    draft.bodyMarkdown = store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown
    return SourceInput(draft: draft, profile: profile)
  }

  private func currentDigest(for input: SourceInput) -> String? {
    if let snapshot = store.cachedPublishPreview(for: input.draft.id),
      snapshot.context.profileID == input.profile.id,
      snapshot.publishPackage.markdownPath == input.profile.markdownPath(for: input.draft)
    {
      return snapshot.publishPackage.sourceDocumentDigest
    }
    guard resolvedSource?.input == input else { return nil }
    return resolvedSource?.digest
  }

  private func systemImage(
    for stage: ArticlePublicationStatusPresentation.Stage
  ) -> String {
    switch stage {
    case .draft: return "square.and.pencil"
    case .ready: return "paperplane"
    case .pendingChanges: return "arrow.up.circle"
    case .waitingForDeployment: return "hourglass"
    case .verifyingArticle: return "doc.text.magnifyingglass"
    case .verifiedOnline: return "checkmark.circle.fill"
    case .needsAttention: return "exclamationmark.triangle.fill"
    }
  }

  private func color(
    for stage: ArticlePublicationStatusPresentation.Stage
  ) -> Color {
    switch stage {
    case .draft: return .secondary
    case .ready: return WorkbenchTheme.success
    case .pendingChanges: return WorkbenchTheme.info
    case .waitingForDeployment, .verifyingArticle: return .secondary
    case .verifiedOnline: return WorkbenchTheme.success
    case .needsAttention: return WorkbenchTheme.warning
    }
  }
}
