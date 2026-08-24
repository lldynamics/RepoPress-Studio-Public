import Combine
import Foundation

@MainActor
public final class PrivacyProtectionStore: ObservableObject {
  @Published public internal(set) var privacySettings: PrivacyProtectionSettings
  @Published public internal(set) var isQuickHideActive: Bool
  @Published public internal(set) var quickHideReason: String?

  init(
    privacySettings: PrivacyProtectionSettings = .default,
    isQuickHideActive: Bool = false,
    quickHideReason: String? = nil
  ) {
    self.privacySettings = privacySettings
    self.isQuickHideActive = isQuickHideActive
    self.quickHideReason = quickHideReason
  }

  public var canUseProtectedWorkbench: Bool {
    !isQuickHideActive
  }

  public var quickHideOperationMessage: String {
    "快速隐藏已启用，请返回工作台后再继续。"
  }

  public var privacyProtectionStatus: PrivacyProtectionStatus {
    PrivacyProtectionStatus.make(
      settings: privacySettings,
      isQuickHideActive: isQuickHideActive,
      reason: quickHideReason
    )
  }

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings, store: WorkbenchStore) {
    privacySettings = settings.normalized
    store.save()
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }
    return PrivateContentDisplay(title: draft.title, summary: "内容已遮挡", isMasked: true)
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty else { return true }
    if draft.isPrivate, privacySettings.masksPrivateContent {
      let protectedHaystack = [draft.title, "私密文章", "内容已遮挡"]
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

  public func activateQuickHide(reason: String? = nil) {
    isQuickHideActive = true
    quickHideReason = reason?.nilIfEmpty
  }

  public func deactivateQuickHide() {
    isQuickHideActive = false
    quickHideReason = nil
  }
}
