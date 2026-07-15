import PublishingWorkbenchCore

@MainActor
struct SettingsStoreActions {
  let store: WorkbenchStore
  let storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator

  func checkRepositoryTokenAccess() async {
    await store.checkRepositoryTokenAccess()
  }

  func copyRepositoryAccessEvidence(_ check: RemoteRepositoryAccessCheck) {
    copyToPublishMessage(
      check.accessEvidenceMarkdown,
      successMessage: "已复制仓库 Token 权限证据包。"
    )
  }

  func lockPrivacyFromSettings() {
    store.lockPrivacy(reason: "已从隐私设置快速隐藏工作台内容。")
  }

  func unlockPrivacyFromSettings() {
    store.unlockPrivacy()
  }

  func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    store.updatePrivacySettings(settings)
  }

  func copyPrivacyChecklist() {
    copyToPublishMessage(
      store.privacyProtectionStatus.checklistMarkdown,
      successMessage: "已复制隐私保护清单。"
    )
  }

  func copyPrivacyAuditReport() {
    copyToPublishMessage(
      store.privacyProtectionAudit.checklistMarkdown,
      successMessage: "已复制隐私保护体检报告。"
    )
  }

  func copyPrivacyEvidencePackage() {
    copyToPublishMessage(
      store.privacyProtectionEvidencePackage.checklistMarkdown,
      successMessage: "已复制隐私保护证据包。"
    )
  }

  func purchasePro() async {
    await storeKitProEntitlementCoordinator.purchasePro(store: store)
  }

  func restorePro() async {
    await storeKitProEntitlementCoordinator.restorePro(store: store)
  }

  func copyProStatusSummary() {
    copyToMonetizationMessage(
      store.proStatusSummary.checklistMarkdown,
      successMessage: "已复制 Pro 状态摘要。"
    )
  }

  func copyProAuditChecklist() {
    copyToMonetizationMessage(
      store.proMonetizationAuditReport.checklistMarkdown,
      successMessage: "已复制 StoreKit / Pro 审核清单。"
    )
  }

  func copyProEvidencePackage() {
    copyToMonetizationMessage(
      store.proStoreKitReviewEvidencePackage.checklistMarkdown,
      successMessage: "已复制 StoreKit / Pro 上架证据包。"
    )
  }

  func copyProSandboxSummary() {
    copyToMonetizationMessage(
      store.proSandboxVerificationSummary.checklistMarkdown,
      successMessage: "已复制 StoreKit 沙盒核验摘要。"
    )
  }

  func copyProSandboxEvidence() {
    copyToMonetizationMessage(
      store.proSandboxVerificationSummary.externalVerificationEvidenceMarkdown,
      successMessage: "已复制 StoreKit 外部验证字段。"
    )
  }

  func copyProSandboxRecordCommand() {
    copyToMonetizationMessage(
      store.proSandboxVerificationSummary.externalVerificationRecordingCommandMarkdown,
      successMessage: "已复制 StoreKit 沙盒记录命令。"
    )
  }

  private func copyToPublishMessage(_ value: String, successMessage: String) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message in
      store.setPublishActionMessage(message)
    }
  }

  private func copyToMonetizationMessage(_ value: String, successMessage: String) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message in
      store.setMonetizationMessage(message)
    }
  }
}
