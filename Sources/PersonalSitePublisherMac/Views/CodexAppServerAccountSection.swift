import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct CodexAppServerAccountSection: View {
  @State private var accountStatus: CodexAppServerAccountStatus?
  @State private var rateLimits: CodexAppServerRateLimits?
  @State private var isWorking = false
  @State private var actionMessage: String?
  @State private var isError = false
  @State private var operationTask: Task<Void, Never>?
  @State private var isLogoutConfirmationPresented = false

  var body: some View {
    Section("1. Codex 账户") {
      HStack(spacing: 8) {
        Label(statusTitle, systemImage: statusSystemImage)
          .foregroundStyle(statusColor)
          .accessibilityIdentifier("settings-ai-codex-account-status")

        Spacer()

        if isWorking {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在检查 Codex 账户")
        }

        Button("刷新状态") {
          startRefresh()
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
        if accountStatus?.accountType != "chatgpt" {
          Button(loginButtonTitle) {
            startLogin()
          }
          .workbenchProminentActionStyle()
          .disabled(isWorking)
          .accessibilityIdentifier("settings-ai-codex-account-login")
        }

        if accountStatus?.isAuthenticated == true {
          Button("退出 Codex 登录", role: .destructive) {
            isLogoutConfirmationPresented = true
          }
          .buttonStyle(.borderless)
          .disabled(isWorking)
          .accessibilityIdentifier("settings-ai-codex-account-logout")
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
        Text("登录由本机 codex app-server 完成，可使用 ChatGPT 套餐，不需要在 RepoPress 中填写 API Key。")
        Text("RepoPress 不读取或保存 OAuth 令牌；令牌保存与刷新由 Codex CLI 管理。AI 内容仍会发送到 Codex / ChatGPT。")
      }
      .font(.workbenchMetadata)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-account")
    .task {
      await refresh(showSuccess: false)
    }
    .onDisappear {
      operationTask?.cancel()
      operationTask = nil
    }
    .confirmationDialog(
      "退出 Codex 登录？",
      isPresented: $isLogoutConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("退出登录", role: .destructive) {
        startLogout()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会退出 Codex CLI 当前账户；其他使用同一 Codex 登录的应用也可能需要重新登录。")
    }
  }

  private var statusTitle: String {
    if isWorking, accountStatus == nil {
      return String(localized: "正在检查 Codex 账户…")
    }
    guard let accountStatus else {
      return String(localized: "Codex 状态不可用")
    }
    if accountStatus.isAuthenticated {
      return accountStatus.accountType == "chatgpt"
        ? String(localized: "已通过 ChatGPT 登录")
        : String(localized: "Codex 已登录")
    }
    return String(localized: "尚未登录 Codex")
  }

  private var loginButtonTitle: String {
    accountStatus?.isAuthenticated == true
      ? String(localized: "改用 ChatGPT 套餐登录")
      : String(localized: "使用 ChatGPT 登录")
  }

  private var statusSystemImage: String {
    guard let accountStatus else { return "exclamationmark.triangle" }
    return accountStatus.isAuthenticated ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark"
  }

  private var statusColor: Color {
    guard let accountStatus else { return isWorking ? .secondary : WorkbenchTheme.warning }
    return accountStatus.isAuthenticated ? WorkbenchTheme.success : .secondary
  }

  private func loginMethodTitle(_ status: CodexAppServerAccountStatus) -> String {
    switch status.accountType {
    case "chatgpt":
      return "ChatGPT OAuth"
    case "apiKey":
      return "Codex CLI API Key"
    case let value?:
      return value
    case nil:
      return "Codex CLI"
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

  private func startRefresh() {
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      await refresh(showSuccess: true)
      operationTask = nil
    }
  }

  @MainActor
  private func refresh(showSuccess: Bool) async {
    isWorking = true
    defer { isWorking = false }
    do {
      let status = try await CodexAppServerClient.shared.accountStatus()
      accountStatus = status
      if status.isAuthenticated {
        do {
          rateLimits = try await CodexAppServerClient.shared.rateLimits()
        } catch {
          // Account state remains useful when optional quota metadata is unavailable.
          rateLimits = nil
        }
      } else {
        rateLimits = nil
      }
      isError = false
      if showSuccess {
        actionMessage = status.isAuthenticated
          ? String(localized: "Codex 登录状态已刷新。")
          : String(localized: "Codex 尚未登录。")
      } else {
        actionMessage = nil
      }
    } catch {
      accountStatus = nil
      rateLimits = nil
      isError = true
      actionMessage = error.localizedDescription
    }
  }

  private func startLogin() {
    operationTask?.cancel()
    operationTask = Task { @MainActor in
      isWorking = true
      isError = false
      actionMessage = String(localized: "正在打开 ChatGPT 登录页面…")
      do {
        let login = try await CodexAppServerClient.shared.startChatGPTLogin()
        guard NSWorkspace.shared.open(login.authURL) else {
          isWorking = false
          isError = true
          actionMessage = String(localized: "无法打开 ChatGPT 登录页面，请检查默认浏览器设置。")
          operationTask = nil
          return
        }
        actionMessage = String(localized: "请在浏览器完成登录；RepoPress 会自动刷新状态。")
        for _ in 0..<60 {
          try Task.checkCancellation()
          try await Task.sleep(for: .seconds(2))
          let status = try await CodexAppServerClient.shared.accountStatus()
          if status.isAuthenticated, status.accountType == "chatgpt" {
            accountStatus = status
            do {
              rateLimits = try await CodexAppServerClient.shared.rateLimits()
            } catch {
              // Successful login does not depend on optional quota metadata.
              rateLimits = nil
            }
            isWorking = false
            actionMessage = String(localized: "ChatGPT 登录成功。")
            operationTask = nil
            return
          }
        }
        isWorking = false
        actionMessage = String(localized: "浏览器授权完成后，请点“刷新状态”。")
      } catch is CancellationError {
        isWorking = false
      } catch {
        isWorking = false
        isError = true
        actionMessage = error.localizedDescription
      }
      operationTask = nil
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
        isError = false
        actionMessage = String(localized: "已退出 Codex 登录。")
      } catch {
        isError = true
        actionMessage = error.localizedDescription
      }
    }
  }
}
