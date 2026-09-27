import Combine
import Foundation
import PublishingCoreSupport

@MainActor
public final class PrivacyProtectionStore: ObservableObject {
  @Published public internal(set) var privacySettings: PrivacyProtectionSettings
  init(privacySettings: PrivacyProtectionSettings = .default) {
    self.privacySettings = privacySettings
  }

  public var privacyProtectionStatus: PrivacyProtectionStatus {
    PrivacyProtectionStatus.make(settings: privacySettings)
  }

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings, store: WorkbenchStore) {
    privacySettings = settings.normalized
    store.save()
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }
    return PrivateContentDisplay(
      title: draft.title,
      summary: CoreL10n.text("内容已遮挡"),
      isMasked: true
    )
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty else { return true }
    if draft.isPrivate, privacySettings.masksPrivateContent {
      let protectedHaystack = [draft.title, CoreL10n.text("私密文章"), CoreL10n.text("内容已遮挡")]
        .joined(separator: " ")
        .lowercased()
      return protectedHaystack.contains(trimmedQuery.lowercased())
    }
    let haystack = [
      draft.title,
      draft.slug,
      draft.summary,
      draft.tags.joined(separator: " "),
      draft.categories.joined(separator: " "),
      profile.markdownPath(for: draft)
    ].joined(separator: " ").lowercased()
    return haystack.contains(trimmedQuery.lowercased())
  }

  public func privacyProtectedSearchDraft(for draft: ArticleDraft) -> ArticleDraft {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return draft
    }
    var protectedDraft = draft
    protectedDraft.slug = ""
    protectedDraft.summary = ""
    protectedDraft.bodyMarkdown = ""
    protectedDraft.tags = []
    protectedDraft.categories = []
    protectedDraft.authors = []
    protectedDraft.detachFromRepository()
    return protectedDraft
  }

}
