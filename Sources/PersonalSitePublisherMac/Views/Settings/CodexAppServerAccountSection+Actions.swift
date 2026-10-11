import Foundation
import PublishingAICore
import SwiftUI

extension CodexAppServerAccountSection {
  func startRefreshAll(showSuccess: Bool) {
    invalidateAccountAction()
    let actionID = accountActionID
    isWorking = true
    operationTask = Task { @MainActor in
      await connection.refresh()
      guard isCurrentAction(actionID) else { return }
      guard runtimeStatus?.isCompatible == true else {
        invalidateModels()
        isError = true
        actionMessage = showSuccess ? (connection.failure ?? runtimeRecoveryMessage) : nil
        isWorking = false
        operationTask = nil
        return
      }
      await refreshAccountDetails(showSuccess: showSuccess, actionID: actionID)
      if isCurrentAction(actionID) { operationTask = nil }
    }
  }

  func refreshReadyAccountDetailsIfNeeded() {
    guard isViewActive, connection.phase == .ready, !connection.isPreparing,
      accountStatus?.isAuthenticated == true, !isWorking, !login.isBusy,
      availableModels.isEmpty, modelTask == nil
    else { return }
    let actionID = accountActionID
    isWorking = true
    operationTask = Task { @MainActor in
      await refreshAccountDetails(showSuccess: false, actionID: actionID)
      if isCurrentAction(actionID) { operationTask = nil }
    }
  }

  func isCurrentAction(_ actionID: UUID) -> Bool {
    isViewActive && !Task.isCancelled && accountActionID == actionID
  }

  @MainActor
  func refreshAccountDetails(showSuccess: Bool, actionID: UUID) async {
    guard isCurrentAction(actionID) else { return }
    isWorking = true
    defer { if accountActionID == actionID { isWorking = false } }
    guard let status = accountStatus else {
      invalidateModels()
      isError = true
      actionMessage = connection.failure ?? String(localized: "ChatGPT 状态不可用")
      return
    }
    if status.isAuthenticated {
      // Model and quota reads have independent owners. A quota outage must not
      // hold back the catalog or cancel an already-running connection test.
      let models = startModelRefresh()
      await connection.refreshRateLimits()
      await models?.value
    } else {
      invalidateModels()
    }
    guard isCurrentAction(actionID), accountStatus == status else { return }
    isError = false
    if showSuccess {
      actionMessage =
        status.isAuthenticated
        ? String(localized: "ChatGPT 登录状态已刷新。") : String(localized: "ChatGPT 尚未登录。")
    } else {
      actionMessage = nil
    }
  }

  @discardableResult
  func startModelRefresh() -> Task<Void, Never>? {
    guard isViewActive, let account = accountStatus, account.isAuthenticated else { return nil }
    if let modelTask { return modelTask }
    let requestID = UUID()
    modelRequestID = requestID
    let revision = connection.accountRevision
    isLoadingModels = true
    let task = Task { @MainActor in
      defer {
        if modelRequestID == requestID {
          isLoadingModels = false
          modelTask = nil
        }
      }
      do {
        let models = try await dependencies.loadModels()
        guard isCurrentModelRead(requestID, revision: revision, account: account) else { return }
        availableModels = models
        modelsError = nil
      } catch is CancellationError {
        return
      } catch CodexAppServerError.cancelled {
        return
      } catch {
        guard isCurrentModelRead(requestID, revision: revision, account: account) else { return }
        modelsError = error.localizedDescription
      }
    }
    modelTask = task
    return task
  }

  func isCurrentModelRead(
    _ requestID: UUID, revision: UInt64, account: CodexAppServerAccountStatus
  ) -> Bool {
    isViewActive && !Task.isCancelled && modelRequestID == requestID
      && connection.accountRevision == revision && accountStatus == account
  }

  func invalidateModels() {
    modelRequestID = UUID()
    modelTask?.cancel()
    modelTask = nil
    availableModels = []
    isLoadingModels = false
    modelsError = nil
  }

  func startBrowserLogin() { startLogin(mode: .browser) }
  func startDeviceCodeLogin() { startLogin(mode: .deviceCode) }

  func startLogin(mode: LoginMode) {
    guard isRuntimeCompatible else {
      isError = true
      actionMessage = runtimeRecoveryMessage
      return
    }
    invalidateAccountAction()
    invalidateModels()
    _ = login.login(
      owner: loginOwnerID, mode: mode, openURL: dependencies.openURL,
      copyDeviceCode: dependencies.copyCode)
  }

  func handleAccountCompletion(_ completion: LoginCompletion) {
    invalidateAccountAction()
    guard completion.result == .loggedIn else {
      invalidateModels()
      isError = false
      actionMessage = String(localized: "已退出 ChatGPT 登录。")
      return
    }
    let contextID = connectionID
    let actionID = accountActionID
    operationTask = Task { @MainActor in
      await finishSuccessfulLogin(completion: completion, contextID: contextID, actionID: actionID)
      if accountActionID == actionID { operationTask = nil }
    }
  }

  @MainActor
  func finishSuccessfulLogin(
    completion: LoginCompletion, contextID: UUID, actionID: UUID
  ) async {
    guard isCurrentLoginCompletion(completion, contextID: contextID) else { return }
    await refreshAccountDetails(showSuccess: false, actionID: actionID)
    guard isCurrentAction(actionID),
      isCurrentLoginCompletion(completion, contextID: contextID),
      accountStatus?.isAuthenticated == true
    else { return }
    isError = false
    if isCodexDataSharingConsentGranted(accountStatus) {
      await runPostLoginConnectionTest()
    } else {
      actionMessage = String(localized: "ChatGPT 登录成功，套餐与用量已刷新。")
      pendingTestCompletion = completion
      pendingTestAccount = accountStatus
      isPostLoginTestConfirmationPresented = true
    }
  }

  func isCurrentLoginCompletion(_ completion: LoginCompletion, contextID: UUID) -> Bool {
    isViewActive && !Task.isCancelled && connectionID == contextID
      && completion.ownerID == loginOwnerID && login.operationID == completion.operationID
  }

  func openRuntimeInstallationGuide() {
    guard let url = URL(string: "https://github.com/openai/codex#readme") else { return }
    _ = dependencies.openURL(url)
  }

  func copyRuntimeInstallationCommand() {
    dependencies.copyCode("brew install --cask codex")
    isError = false
    actionMessage = String(localized: "Homebrew 安装命令已复制。")
  }

  func startPostLoginConnectionTest() {
    guard isViewActive, !login.isBusy else { return }
    invalidateAccountAction()
    let actionID = accountActionID
    operationTask = Task { @MainActor in
      await runPostLoginConnectionTest()
      if accountActionID == actionID { operationTask = nil }
    }
  }

  @MainActor
  func runPostLoginConnectionTest() async {
    let actionID = accountActionID
    let contextID = connectionID
    let loginOperationID = login.operationID
    let account = accountStatus
    let revision = connection.accountRevision
    let isCurrent: @MainActor () -> Bool = {
      isCurrentAction(actionID) && connectionID == contextID
        && login.operationID == loginOperationID && !login.isBusy
        && connection.accountRevision == revision && accountStatus == account
    }
    guard isCurrent(), account?.isAuthenticated == true else { return }
    isWorking = true
    defer {
      if accountActionID == actionID {
        isWorking = false
        if connectionTestState == .testing { connectionTestState = .idle }
      }
    }
    isError = false
    connectionTestState = .testing
    actionMessage = String(localized: "登录成功，正在自动测试连接…")
    let report = await testConnection(isCurrent)
    guard isCurrent() else { return }
    if let report {
      connectionTestState = .passed
      actionMessage = report.headline
    } else {
      connectionTestState = .failed
      isError = true
      actionMessage = String(localized: "登录成功，但自动连接测试失败；你可以稍后重试。")
    }
  }

  func startLogout() {
    invalidateAccountAction()
    invalidateModels()
    _ = login.logout(owner: loginOwnerID)
  }

  func invalidateAccountAction() {
    actionMessage = nil
    isError = false
    accountActionID = UUID()
    pendingTestCompletion = nil
    pendingTestAccount = nil
    isPostLoginTestConfirmationPresented = false
    operationTask?.cancel()
    operationTask = nil
    isWorking = false
    connectionTestState = .idle
  }
}
