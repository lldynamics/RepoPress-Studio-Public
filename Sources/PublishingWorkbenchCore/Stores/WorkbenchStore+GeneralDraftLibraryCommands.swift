import Foundation

extension WorkbenchStore {
  public func generalDraftSourceFieldDiffs(for draft: ArticleDraft) -> [String] {
    publishingStore.generalDraftSourceFieldDiffs(for: draft)
  }

  public var generalDraftLibraryReport: GeneralDraftLibraryReport {
    publishingStore.generalDraftLibraryReport(store: self)
  }

  public var generalDraftLibraryPackagePlan: GeneralDraftLibraryPackagePlan {
    publishingStore.generalDraftLibraryPackagePlan()
  }

  public var generalDraftBackupPlan: GeneralDraftBackupPlan {
    publishingStore.generalDraftBackupPlan()
  }

  @discardableResult
  public func writeGeneralDraftBackupToRepository() -> GeneralDraftBackupWriteResult? {
    publishingStore.writeGeneralDraftBackupToRepository(store: self)
  }

  @discardableResult
  public func ensureGeneralDraftProfile() -> SiteProfile {
    publishingStore.ensureGeneralDraftProfile(store: self)
  }

  @discardableResult
  public func createGeneralDraft() -> ArticleDraft {
    publishingStore.createGeneralDraft(store: self)
  }

  @discardableResult
  public func copyDraftToGeneralLibrary(_ draftID: UUID) -> ArticleDraft? {
    publishingStore.copyDraftToGeneralLibrary(draftID, store: self)
  }

  @discardableResult
  public func copyDraftToActiveProfile(_ draftID: UUID) -> ArticleDraft? {
    publishingStore.copyDraftToActiveProfile(draftID, store: self)
  }

  @discardableResult
  public func copyDraft(_ draftID: UUID, toProfileID profileID: UUID) -> ArticleDraft? {
    publishingStore.copyDraft(draftID, toProfileID: profileID, store: self)
  }

  @discardableResult
  public func importGeneralDraftLibraryPackage(from packageText: String) -> LocalContentImportMergeSummary {
    publishingStore.importGeneralDraftLibraryPackage(from: packageText, store: self)
  }

}
