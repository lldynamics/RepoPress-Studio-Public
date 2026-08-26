import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct CodexAppServerAccountSection: View {
  let model: Binding<String>
  let reasoningEffortOverride: Binding<String?>
  let isCodexDataSharingConsentGranted: (CodexAppServerAccountStatus?) -> Bool
  let grantConsentForConnection: (CodexAppServerAccountStatus) -> Void
  let testConnection: () async -> AIConnectionTestReport?

  @State private var runtimeStatus: CodexAppServerRuntimeStatus?
  @State private var accountStatus: CodexAppServerAccountStatus?
  @State private var rateLimits: CodexAppServerRateLimits?
  @State private var availableModels: [CodexAppServerModel] = []
  @State private var isLoadingModels = false
  @State private var modelsError: String?
  @State private var deviceCodeLogin: CodexAppServerDeviceCodeLoginResult?
  @State private var isWorking = false
  @State private var isLoginFlowActive = false
  @State private var actionMessage: String?
  @State private var isError = false
  @State private var operationTask: Task<Void, Never>?
  @State private var isLogoutConfirmationPresented = false
  @State private var isPostLoginTestConfirmationPresented = false

  var body: some View {
    Group {
      Section("ChatGPT 账户") {
        CodexAppServerRuntimeStatusContent(
          runtimeStatus: runtimeStatus,
          openInstallationGuide: openRuntimeInstallationGuide,
          copyInstallationCommand: copyRuntimeInstallationCommand
        )

        HStack(spacing: 8) {
          Label(statusTitle, systemImage: statusSystemImage)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("settings-ai-codex-account-status")

          Spacer()

          if isWorking {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在检查 ChatGPT 账户")
          }

          Button("重新检测") {
            startRefreshAll()
          }
          .buttonStyle(.borderless)
          .disabled(isWorking)
          .accessibilityIdentifier("settings-ai-codex-account-refresh")
        }

        if let accountStatus, accountStatus.isAuthenticated {
          LabeledContent("登录方式", value: loginMethodTitle(accountStatus))
          if let email = accountStatus.email?.trimmedForPublishing.nilIfEmpty {
            LabeledContent("账户", value: email)
          }
          if let plan = accountStatus.planType?.trimmedForPublishing.nilIfEmpty {
            LabeledContent("套餐", value: planTitle(plan))
          }
          if let primary = rateLimits?.primary?.usedPercent {
            LabeledContent("当前用量", value: "\(Int(primary.rounded()))%")
          }
        }

        HStack(spacing: 10) {
          if runtimeStatus?.isAvailable == true, accountStatus?.isAuthenticated != true {
            Button(loginButtonTitle) {
              startBrowserLogin()
            }
            .workbenchProminentActionStyle()
            .disabled(isWorking)
            .accessibilityIdentifier("settings-ai-codex-account-login")
          }

          if accountStatus?.isAuthenticated == true {
            Button("退出 ChatGPT 登录", role: .destructive) {
              isLogoutConfirmationPresented = true
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .accessibilityIdentifier("settings-ai-codex-account-logout")
          }

          if let accountStatus,
            accountStatus.isAuthenticated,
            !isCodexDataSharingConsentGranted(accountStatus)
          {
            Button("同意并测试 ChatGPT 连接") {
              grantConsentForConnection(accountStatus)
              startPostLoginConnectionTest()
            }
            .workbenchProminentActionStyle()
            .disabled(isWorking)
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
            .disabled(isWorking)
            .accessibilityIdentifier("settings-ai-codex-account-test")
          }

          if isLoginFlowActive, accountStatus?.isAuthenticated != true {
            Button("取消登录", role: .cancel) {
              operationTask?.cancel()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-ai-codex-account-cancel-login")
          }
        }

        if runtimeStatus?.isAvailable == true, accountStatus?.isAuthenticated != true {
          Button("改用设备码登录") {
            startDeviceCodeLogin()
          }
          .buttonStyle(.link)
          .disabled(isWorking)
          .accessibilityHint("浏览器回跳不可用时使用")
          .accessibilityIdentifier("settings-ai-codex-device-login")
        }

        if let deviceCodeLogin {
          CodexAppServerDeviceCodeContent(deviceCodeLogin) {
            actionMessage = String(localized: "设备码已复制。")
          }
        }

        if let actionMessage {
          AccessibleStatusMessage(
            message: actionMessage,
            severity: isError ? .error : .success,
            announcesNonUrgentStatus: true
          )
          .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("使用 ChatGPT 套餐登录，不需要在 RepoPress 中填写 API Key。")
          Text("RepoPress 不读取或保存登录令牌。AI 内容仍会发送到 OpenAI，并在首次发送前征求你的确认。")
        }
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      }
      if let accountStatus, accountStatus.isAuthenticated {
        CodexAppServerModelSelectionSection(
          model: model,
          reasoningEffortOverride: reasoningEffortOverride,
          models: availableModels,
          isLoading: isLoadingModels,
          errorMessage: modelsError,
          onRefresh: startModelRefresh
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-account")
    .task {
      await refreshAll(showSuccess: false)
    }
    .onDisappear {
      operationTask?.cancel()
      operationTask = nil
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
        guard let accountStatus else { return }
        grantConsentForConnection(accountStatus)
        startPostLoginConnectionTest()
      }
      Button("稍后", role: .cancel) {}
    } message: {
      Text("测试会向 OpenAI 发送一条不含文章或资料库内容的最小请求，并保存此目的地的发送授权。")
    }
  }

  private var statusTitle: String {
    if isWorking, accountStatus == nil {
      return String(localized: "正在检查 ChatGPT 账户…")
    }
    guard let accountStatus else {
      return runtimeStatus?.isAvailable == false
        ? String(localized: "需要安装运行组件")
        : String(localized: "ChatGPT 状态不可用")
    }
    if accountStatus.isAuthenticated {
      return accountStatus.accountType == "chatgpt"
        ? String(localized: "已通过 ChatGPT 登录")
        : String(localized: "已登录其他账户")
    }
    return String(localized: "尚未登录 ChatGPT")
  }

  private var loginButtonTitle: String {
    accountStatus?.isAuthenticated == true
      ? String(localized: "改用 ChatGPT 套餐登录")
      : String(localized: "使用 ChatGPT 登录")
  }

  private var statusSystemImage: String {
    guard let accountStatus else { return "exclamationmark.triangle" }
    return accountStatus.isAuthenticated
      ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark"
  }

  private var statusColor: Color {
    guard let accountStatus else { return isWorking ? .secondary : WorkbenchTheme.warning }
    return accountStatus.isAuthenticated ? WorkbenchTheme.success : .secondary
  }

  private func loginMethodTitle(_ status: CodexAppServerAccountStatus) -> String {
    switch status.accountType {
    case "chatgpt": return "ChatGPT"
    case "apiKey": return "API Key"
    case let value?: return value
    case nil: return "ChatGPT"
    }
  }

  private func planTitle(_ plan: String) -> String {
    switch plan.lowercased() {
    case "free": return "Free"
    case "go": return "Go"
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "prolite": return "Pro Lite"
    case "team": return "Team"
    case "business", "self_serve_business_usage_based": return "Business"
    case "enterprise", "enterprise_cbp_usage_based": return "Enterprise"
    case "edu": return "Edu"
    default: return plan
    }
  }

  private func startRefreshAll() {
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      await refreshAll(showSuccess: true)
      operationTask = nil
    }
  }

  @MainActor
  private func refreshAll(showSuccess: Bool) async {
    isWorking = true
    runtimeStatus = await CodexAppServerProcessTransport.inspectRuntime()
    guard runtimeStatus?.isAvailable == true else {
      accountStatus = nil
      rateLimits = nil
      availableModels = []
      isLoadingModels = false
      modelsError = nil
      isError = true
      actionMessage = showSuccess ? String(localized: "未找到 Codex 运行组件。") : nil
      isWorking = false
      return
    }
    await refresh(showSuccess: showSuccess)
  }

  @MainActor
  private func refresh(showSuccess: Bool) async {
    isWorking = true
    defer { isWorking = false }
    do {
      let status = try await CodexAppServerClient.shared.accountStatus()
      accountStatus = status
      if status.isAuthenticated {
        isLoadingModels = true
        do {
          rateLimits = try await CodexAppServerClient.shared.rateLimits()
        } catch {
          // Optional quota metadata must not hide a valid authenticated account.
          rateLimits = nil
        }
        await refreshModels()
      } else {
        rateLimits = nil
        availableModels = []
        isLoadingModels = false
        modelsError = nil
      }
      isError = false
      if showSuccess {
        actionMessage =
          status.isAuthenticated
          ? String(localized: "ChatGPT 登录状态已刷新。")
          : String(localized: "ChatGPT 尚未登录。")
      } else {
        actionMessage = nil
      }
    } catch {
      accountStatus = nil
      rateLimits = nil
      availableModels = []
      isLoadingModels = false
      modelsError = nil
      isError = true
      actionMessage = error.localizedDescription
    }
  }

  private func startModelRefresh() {
    guard accountStatus?.isAuthenticated == true else { return }
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      await refreshModels()
      operationTask = nil
    }
  }

  @MainActor
  private func refreshModels() async {
    guard accountStatus?.isAuthenticated == true else { return }
    isLoadingModels = true
    defer { isLoadingModels = false }
    do {
      availableModels = try await CodexAppServerClient.shared.models(includeHidden: false)
      modelsError = nil
    } catch is CancellationError {
      return
    } catch CodexAppServerError.cancelled {
      return
    } catch {
      // A model catalog outage must not invalidate an otherwise valid login.
      modelsError = error.localizedDescription
    }
  }

  private func startBrowserLogin() {
    operationTask?.cancel()
    isLoginFlowActive = true
    operationTask = Task { @MainActor in
      isWorking = true
      isError = false
      actionMessage = String(localized: "正在打开 ChatGPT 登录页面…")
      do {
        let login = try await CodexAppServerClient.shared.startChatGPTLogin()
        guard NSWorkspace.shared.open(login.authURL) else {
          isWorking = false
          isLoginFlowActive = false
          isError = true
          actionMessage = String(localized: "无法打开 ChatGPT 登录页面，请检查默认浏览器设置。")
          operationTask = nil
          return
        }
        actionMessage = String(localized: "请在浏览器完成登录；完成后此处会自动更新。")
        try await CodexAppServerClient.shared.waitForLoginCompletion(loginID: login.loginID)
        await finishSuccessfulLogin()
      } catch is CancellationError {
        finishCancelledLogin()
      } catch CodexAppServerError.cancelled {
        finishCancelledLogin()
      } catch {
        isWorking = false
        isLoginFlowActive = false
        isError = true
        actionMessage = error.localizedDescription
      }
      operationTask = nil
    }
  }

  private func startDeviceCodeLogin() {
    operationTask?.cancel()
    isLoginFlowActive = true
    operationTask = Task { @MainActor in
      isWorking = true
      isError = false
      actionMessage = String(localized: "正在创建设备码…")
      do {
        let login = try await CodexAppServerClient.shared.startChatGPTDeviceCodeLogin()
        deviceCodeLogin = login
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login.userCode, forType: .string)
        _ = NSWorkspace.shared.open(login.verificationURL)
        actionMessage = String(localized: "设备码已复制。请在浏览器完成登录。")
        try await CodexAppServerClient.shared.waitForLoginCompletion(loginID: login.loginID)
        await finishSuccessfulLogin()
      } catch is CancellationError {
        finishCancelledLogin()
      } catch CodexAppServerError.cancelled {
        finishCancelledLogin()
      } catch {
        isWorking = false
        isLoginFlowActive = false
        isError = true
        actionMessage = error.localizedDescription
      }
      operationTask = nil
    }
  }

  @MainActor
  private func finishSuccessfulLogin() async {
    isLoginFlowActive = false
    deviceCodeLogin = nil
    await refresh(showSuccess: false)
    guard accountStatus?.isAuthenticated == true else {
      isWorking = false
      return
    }
    isError = false
    if isCodexDataSharingConsentGranted(accountStatus) {
      await runPostLoginConnectionTest()
    } else {
      isWorking = false
      actionMessage = String(localized: "ChatGPT 登录成功，套餐与用量已刷新。")
      isPostLoginTestConfirmationPresented = true
    }
  }

  @MainActor
  private func finishCancelledLogin() {
    isWorking = false
    isLoginFlowActive = false
    isError = false
    deviceCodeLogin = nil
    actionMessage = String(localized: "登录已取消。")
  }

  private func openRuntimeInstallationGuide() {
    guard let url = URL(string: "https://github.com/openai/codex#readme") else { return }
    _ = NSWorkspace.shared.open(url)
  }

  private func copyRuntimeInstallationCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("brew install --cask codex", forType: .string)
    isError = false
    actionMessage = String(localized: "Homebrew 安装命令已复制。")
  }

  private func startPostLoginConnectionTest() {
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      await runPostLoginConnectionTest()
      operationTask = nil
    }
  }

  @MainActor
  private func runPostLoginConnectionTest() async {
    isWorking = true
    isError = false
    actionMessage = String(localized: "登录成功，正在自动测试连接…")
    let report = await testConnection()
    isWorking = false
    if let report {
      actionMessage = report.headline
    } else {
      isError = true
      actionMessage = String(localized: "登录成功，但自动连接测试失败；你可以稍后重试。")
    }
  }

  private func startLogout() {
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      isWorking = true
      defer {
        isWorking = false
        operationTask = nil
      }
      do {
        try await CodexAppServerClient.shared.logout()
        accountStatus = CodexAppServerAccountStatus(isAuthenticated: false)
        rateLimits = nil
        availableModels = []
        isLoadingModels = false
        modelsError = nil
        isError = false
        actionMessage = String(localized: "已退出 ChatGPT 登录。")
      } catch {
        isError = true
        actionMessage = error.localizedDescription
      }
    }
  }
}
