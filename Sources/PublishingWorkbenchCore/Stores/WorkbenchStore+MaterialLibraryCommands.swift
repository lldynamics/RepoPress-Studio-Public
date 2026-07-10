import Foundation

extension WorkbenchStore {
  public func generalDraftSourceFieldDiffs(for draft: ArticleDraft) -> [String] {
    publishingStore.generalDraftSourceFieldDiffs(for: draft)
  }

  public var generalDraftLibraryReport: GeneralDraftLibraryReport {
    publishingStore.generalDraftLibraryReport(store: self)
  }

  public var materialLibraryReport: MaterialLibraryReport {
    generalDraftLibraryReport
  }

  public var generalDraftLibraryPackagePlan: GeneralDraftLibraryPackagePlan {
    publishingStore.generalDraftLibraryPackagePlan()
  }

  public var materialLibraryPackagePlan: MaterialLibraryPackagePlan {
    generalDraftLibraryPackagePlan
  }

  public var generalDraftBackupPlan: GeneralDraftBackupPlan {
    publishingStore.generalDraftBackupPlan()
  }

  public var materialLibraryBackupPlan: MaterialLibraryBackupPlan {
    generalDraftBackupPlan
  }

  @discardableResult
  public func writeGeneralDraftBackupToRepository() -> GeneralDraftBackupWriteResult? {
    publishingStore.writeGeneralDraftBackupToRepository(store: self)
  }

  @discardableResult
  public func writeMaterialLibraryBackupToRepository() -> MaterialLibraryBackupWriteResult? {
    writeGeneralDraftBackupToRepository()
  }

  @discardableResult
  public func ensureGeneralDraftProfile() -> SiteProfile {
    publishingStore.ensureGeneralDraftProfile(store: self)
  }

  @discardableResult
  public func ensureMaterialLibraryProfile() -> SiteProfile {
    ensureGeneralDraftProfile()
  }

  @discardableResult
  public func createGeneralDraft() -> ArticleDraft {
    publishingStore.createGeneralDraft(store: self)
  }

  @discardableResult
  public func createMaterial() -> ArticleDraft {
    createGeneralDraft()
  }

  @discardableResult
  public func copyDraftToGeneralLibrary(_ draftID: UUID) -> ArticleDraft? {
    publishingStore.copyDraftToGeneralLibrary(draftID, store: self)
  }

  @discardableResult
  public func copyDraftToMaterialLibrary(_ draftID: UUID) -> ArticleDraft? {
    copyDraftToGeneralLibrary(draftID)
  }

  @discardableResult
  public func copyDraftToActiveProfile(_ draftID: UUID) -> ArticleDraft? {
    publishingStore.copyDraftToActiveProfile(draftID, store: self)
  }

  @discardableResult
  public func importGeneralDraftLibraryPackage(from packageText: String) -> LocalContentImportMergeSummary {
    publishingStore.importGeneralDraftLibraryPackage(from: packageText, store: self)
  }

  @discardableResult
  public func importMaterialLibraryPackage(from packageText: String) -> LocalContentImportMergeSummary {
    importGeneralDraftLibraryPackage(from: packageText)
  }
}
