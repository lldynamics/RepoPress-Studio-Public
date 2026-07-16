import Foundation

extension WorkbenchStore {
  public func generalDraftSourceFieldDiffs(for draft: ArticleDraft) -> [String] {
    publishingStore.generalDraftSourceFieldDiffs(for: draft)
  }

  public var generalDraftLibraryReport: GeneralDraftLibraryReport {
    publishingStore.generalDraftLibraryReport(store: self)
  }

  @discardableResult
  public func copyDraft(_ draftID: UUID, toProfileID profileID: UUID) -> ArticleDraft? {
    publishingStore.copyDraft(draftID, toProfileID: profileID, store: self)
  }

}
