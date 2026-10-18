import AppKit
import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

struct CodexAppServerAccountSection: View {
  let connectionID: UUID
  let model: Binding<String>
  let reasoningEffortOverride: Binding<String?>
  let isCodexDataSharingConsentGranted: (CodexAppServerAccountStatus?) -> Bool
  let grantConsentForConnection: (CodexAppServerAccountStatus) -> Void
  let testConnection: (@MainActor () -> Bool) async -> AIConnectionTestReport?

  let dependencies: CodexAccountSectionDependencies
  typealias LoginMode = CodexAccountLoginCoordinator.Mode
  typealias LoginCompletion = CodexAccountLoginCoordinator.Completion
  @ObservedObject var connection: CodexConnectionController
  @State var availableModels: [CodexAppServerModel] = []
  @State var isLoadingModels = false
  @State var modelsError: String?
  @ObservedObject var login: CodexAccountLoginCoordinator
  @State var loginOwnerID = UUID()
  @State var isViewActive = false
  @State var isWorking = false
  @State var actionMessage: String?
  @State var isError = false
  @State var connectionTestState: CodexAppServerConnectionTestState = .idle
  @State var operationTask: Task<Void, Never>?
  @State var modelTask: Task<Void, Never>?
  @State var modelRequestID = UUID()
  @State var accountActionID = UUID()
  @State var pendingTestCompletion: CodexAccountLoginCoordinator.Completion?
  @State var pendingTestAccount: CodexAppServerAccountStatus?
  @State var isLogoutConfirmationPresented = false
  @State var isPostLoginTestConfirmationPresented = false

  init(
    connectionID: UUID, model: Binding<String>, reasoningEffortOverride: Binding<String?>,
    isCodexDataSharingConsentGranted: @escaping (CodexAppServerAccountStatus?) -> Bool,
    grantConsentForConnection: @escaping (CodexAppServerAccountStatus) -> Void,
    dependencies: CodexAccountSectionDependencies? = nil,
    testConnection: @escaping (@MainActor () -> Bool) async -> AIConnectionTestReport?
  ) {
    self.connectionID = connectionID
    self.model = model
    self.reasoningEffortOverride = reasoningEffortOverride
    self.isCodexDataSharingConsentGranted = isCodexDataSharingConsentGranted
    self.grantConsentForConnection = grantConsentForConnection
    let dependencies = dependencies ?? .live
    self.dependencies = dependencies
    _connection = ObservedObject(wrappedValue: dependencies.connection)
    _login = ObservedObject(wrappedValue: dependencies.login)
    self.testConnection = testConnection
  }

  var rateLimits: CodexAppServerRateLimits? { connection.rateLimits }

  var body: some View {
    Group {
      Section("ChatGPT 账户") {
        CodexRuntimeSetupSection(connection: connection)
        CodexAppServerRuntimeStatusContent(
          runtimeStatus: runtimeStatus,
          openInstallationGuide: openRuntimeInstallationGuide,
          copyInstallationCommand: copyRuntimeInstallationCommand
        )

        CodexAppServerAccountSetupSteps(
          runtimeStatus: runtimeStatus,
          accountStatus: accountStatus,
          consentGranted: accountStatus.map {
            isCodexDataSharingConsentGranted($0)
          } ?? false,
          connectionTestState: connectionTestState
        )

        HStack(spacing: 8) {
          Label(statusTitle, systemImage: statusSystemImage)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("settings-ai-codex-account-status")

          Spacer()

          if isOperationWorking {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在检查 ChatGPT 账户")
          }

          Button("重新检测") {
            startRefreshAll(showSuccess: true)
          }
          .buttonStyle(.borderless)
          .disabled(isOperationWorking)
          .accessibilityIdentifier("settings-ai-codex-account-refresh")
        }

        if let accountStatus, accountStatus.isAuthenticated {
          LabeledContent("登录方式", value: CodexAccountLabels.loginMethodTitle(accountStatus))
          if let email = accountStatus.email?.trimmedForPublishing.nilIfEmpty {
            LabeledContent("账户", value: email)
          }
          if let plan = accountStatus.planType?.trimmedForPublishing.nilIfEmpty {
            LabeledContent("套餐", value: CodexAccountLabels.planTitle(plan))
          }
          if let primary = rateLimits?.primary?.usedPercent {
            LabeledContent("当前用量", value: "\(Int(primary.rounded()))%")
          }
        }

        HStack(spacing: 10) {
          if runtimeStatus != nil, accountStatus?.isAuthenticated != true {
            Button(loginButtonTitle) {
              startBrowserLogin()
            }
            .workbenchProminentActionStyle()
            .disabled(isOperationWorking || !isRuntimeCompatible)
            .accessibilityHint(runtimeActionHint)
            .accessibilityIdentifier("settings-ai-codex-account-login")
          }

          if accountStatus?.isAuthenticated == true {
            Button("退出 ChatGPT 登录", role: .destructive) {
              isLogoutConfirmationPresented = true
            }
            .buttonStyle(.borderless)
            .disabled(isOperationWorking)
            .accessibilityIdentifier("settings-ai-codex-account-logout")
          }

          if let accountStatus,
            accountStatus.isAuthenticated,
            !isCodexDataSharingConsentGranted(accountStatus)
          {
            Button("同意并测试 ChatGPT 连接") {
              guard isViewActive, !login.isBusy else { return }
              grantConsentForConnection(accountStatus)
              startPostLoginConnectionTest()
            }
            .workbenchProminentActionStyle()
            .disabled(isOperationWorking)
            .accessibilityIdentifier("settings-ai-codex-account-consent")
          }

          if let accountStatus,
            accountStatus.isAuthenticated,
            isCodexDataSharingConsentGranted(accountStatus)
          {
            Button("测试 ChatGPT 连接") {
              startPostLoginConnectionTest()
            }
            .buttonStyle(.borderless)
            .disabled(isOperationWorking)
            .accessibilityIdentifier("settings-ai-codex-account-test")
          }

          if login.isLoginFlowActive, accountStatus?.isAuthenticated != true {
            Button("取消登录", role: .cancel) {
              login.cancelLogin(owner: loginOwnerID)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-ai-codex-account-cancel-login")
          }
        }

        if runtimeStatus != nil, accountStatus?.isAuthenticated != true {
          Button("改用设备码登录") {
            startDeviceCodeLogin()
          }
          .buttonStyle(.link)
          .disabled(isOperationWorking || !isRuntimeCompatible)
          .accessibilityHint("浏览器回跳不可用时使用")
          .accessibilityIdentifier("settings-ai-codex-device-login")
        }

        if let deviceCodeLogin = login.deviceCode {
          CodexAppServerDeviceCodeContent(
            deviceCodeLogin, openURL: dependencies.openURL, copyCode: dependencies.copyCode
          ) {
            actionMessage = String(localized: "设备码已复制。")
          }
        }

        if let actionMessage = login.isBusy ? login.message : actionMessage {
          AccessibleStatusMessage(
            message: actionMessage,
            severity: (login.isBusy ? login.isError : isError) ? .error : .success,
            announcesNonUrgentStatus: true
          )
          .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("使用 ChatGPT 套餐登录，不需要在 RepoPress 中填写 API Key。")
          Text("通过本机 Codex 运行组件启动 ChatGPT 登录；令牌由 Codex 运行组件管理。")
          Text("RepoPress 不读取或保存登录令牌。AI 内容仍会发送到 OpenAI，并在首次发送前征求你的确认。")
        }
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
      }
      if let accountStatus, accountStatus.isAuthenticated {
        CodexAppServerModelSelectionSection(
          model: model,
          reasoningEffortOverride: reasoningEffortOverride,
          models: availableModels,
          isLoading: isLoadingModels,
          errorMessage: modelsError,
          onRefresh: { startModelRefresh() }
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-account")
    .task(id: connectionID) {
      isViewActive = true
      guard !login.isBusy else { return }
      startRefreshAll(showSuccess: false)
    }
    .onChange(of: connection.accountRevision) { _, _ in
      invalidateAccountAction()
      invalidateModels()
      refreshReadyAccountDetailsIfNeeded()
    }
    .onChange(of: connectionID) { _, _ in
      invalidateAccountAction()
      invalidateModels()
      login.cancelLogin(owner: loginOwnerID)
    }
    .onChange(of: connection.phase) { _, phase in
      guard phase == .ready else { return }
      refreshReadyAccountDetailsIfNeeded()
    }
    .onChange(of: connection.isPreparing) { _, isPreparing in
      guard !isPreparing else { return }
      refreshReadyAccountDetailsIfNeeded()
    }
    .onChange(of: login.message) { _, message in
      guard isViewActive, login.ownerID == loginOwnerID else { return }
      actionMessage = message
      isError = login.isError
    }
    .onChange(of: login.completion) { _, completion in
      guard let completion, isViewActive, completion.ownerID == loginOwnerID else { return }
      handleAccountCompletion(completion)
    }
    .onChange(of: login.isBusy) { _, busy in
      guard !busy, login.ownerID != loginOwnerID else { return }
      refreshReadyAccountDetailsIfNeeded()
    }
    .onDisappear {
      isViewActive = false
      invalidateAccountAction()
      invalidateModels()
      login.cancelLogin(owner: loginOwnerID)
    }
    .confirmationDialog(
      "退出 ChatGPT 登录？",
      isPresented: $isLogoutConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("退出登录", role: .destructive) {
        startLogout()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会退出本机当前 ChatGPT 账户；其他共用此登录的应用也可能需要重新登录。")
    }
    .confirmationDialog(
      "登录成功，测试连接？",
      isPresented: $isPostLoginTestConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("同意并测试") {
        guard let completion = pendingTestCompletion,
          isCurrentLoginCompletion(completion, contextID: connectionID),
          !login.isBusy, let accountStatus, accountStatus.isAuthenticated,
          accountStatus == pendingTestAccount
        else { return }
        grantConsentForConnection(accountStatus)
        startPostLoginConnectionTest()
      }
      Button("稍后", role: .cancel) { pendingTestCompletion = nil }
    } message: {
      Text("测试会向 OpenAI 发送一条不含文章或资料库内容的最小请求，并保存此目的地的发送授权。")
    }
  }

  private var statusTitle: String {
    guard let runtimeStatus else {
      return isWorking
        ? String(localized: "正在检查 ChatGPT 账户…")
        : String(localized: "ChatGPT 状态不可用")
    }
    guard runtimeStatus.isCompatible else {
      return runtimeStatusTitle(runtimeStatus)
    }
    if isWorking, accountStatus == nil {
      return String(localized: "正在检查 ChatGPT 账户…")
    }
    guard let accountStatus else {
      return String(localized: "ChatGPT 状态不可用")
    }
    if accountStatus.isAuthenticated {
      return accountStatus.accountType == "chatgpt"
        ? String(localized: "已通过 ChatGPT 登录")
        : String(localized: "已登录其他账户")
    }
    return String(localized: "尚未登录 ChatGPT")
  }

  var runtimeStatus: CodexAppServerRuntimeStatus? {
    connection.runtimeStatus
  }

  var accountStatus: CodexAppServerAccountStatus? {
    connection.accountStatus
  }

  private var isOperationWorking: Bool {
    isWorking || login.isBusy || connection.isChecking || connection.isPreparing
  }

  private var loginButtonTitle: String {
    accountStatus?.isAuthenticated == true
      ? String(localized: "改用 ChatGPT 套餐登录")
      : String(localized: "使用 ChatGPT 登录")
  }

  private var statusSystemImage: String {
    guard runtimeStatus?.isCompatible == true, let accountStatus else {
      return "exclamationmark.triangle"
    }
    return accountStatus.isAuthenticated
      ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark"
  }

  private var statusColor: Color {
    guard runtimeStatus?.isCompatible == true else {
      return isWorking ? .secondary : WorkbenchTheme.warning
    }
    guard let accountStatus else { return isWorking ? .secondary : WorkbenchTheme.warning }
    return accountStatus.isAuthenticated ? WorkbenchTheme.success : .secondary
  }

  var isRuntimeCompatible: Bool {
    runtimeStatus?.isCompatible == true
  }

  private var runtimeActionHint: String {
    isRuntimeCompatible
      ? String(localized: "通过本机 Codex 运行组件启动 ChatGPT 登录。")
      : runtimeRecoveryMessage
  }

  private func runtimeStatusTitle(_ status: CodexAppServerRuntimeStatus) -> String {
    switch status.compatibility {
    case .missingExecutable:
      return String(localized: "需要安装运行组件")
    case .missingVersion:
      return String(localized: "运行组件未返回版本号")
    case .unparseableVersion:
      return String(localized: "无法解析运行组件版本")
    case .unsupportedVersion:
      return String(localized: "运行组件版本过低")
    case .compatible:
      return String(localized: "运行组件兼容")
    }
  }

  var runtimeRecoveryMessage: String {
    guard let status = runtimeStatus else {
      return String(localized: "正在检测 Codex 运行组件兼容性…")
    }
    switch status.compatibility {
    case .missingExecutable:
      return String(localized: "未找到 Codex 运行组件。")
    case .missingVersion:
      return String(localized: "Codex 运行组件未返回版本号，请更新后重新检测。")
    case .unparseableVersion:
      return String(localized: "无法解析 Codex 运行组件版本，请更新后重新检测。")
    case .unsupportedVersion:
      return String(localized: "Codex 运行组件版本过低，需要 0.142.0 或更高。")
    case .compatible:
      return String(localized: "Codex 运行组件已兼容。")
    }
  }

}

/// Production effects stay at the boundary so offline GUI tests never touch
/// the shared process, browser, clipboard, or a user's authentication files.
@MainActor
struct CodexAccountSectionDependencies {
  let connection: CodexConnectionController
  let login: CodexAccountLoginCoordinator
  let loadModels: @Sendable () async throws -> [CodexAppServerModel]
  let openURL: @MainActor @Sendable (URL) -> Bool
  let copyCode: @MainActor @Sendable (String) -> Void

  nonisolated static func liveModels() async throws -> [CodexAppServerModel] {
    try await CodexAppServerClient.shared.models(includeHidden: false)
  }

  static var live: Self {
    Self(
      connection: .shared, login: .shared,
      loadModels: liveModels,
      openURL: { NSWorkspace.shared.open($0) },
      copyCode: {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
      })
  }
}
