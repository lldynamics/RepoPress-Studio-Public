import Combine
import Foundation
import PublishingAICore

public protocol CodexAccountLoginServing: Sendable {
  func startChatGPTLogin() async throws -> CodexAppServerLoginResult
  func startChatGPTDeviceCodeLogin() async throws -> CodexAppServerDeviceCodeLoginResult
  func waitForLoginCompletion(loginID: String) async throws
  func cancelLogin(loginID: String) async
  func logout() async throws
}

extension CodexAppServerClient: CodexAccountLoginServing {}

/// Owns one account-changing operation for the application. Connection-specific
/// consent and test callbacks stay in their originating settings view.
@MainActor
public final class CodexAccountLoginCoordinator: ObservableObject {
  public enum Mode: Equatable, Sendable { case browser, deviceCode }
  public enum Phase: Equatable, Sendable {
    case idle, starting, waiting, cancelling, loggingOut, succeeded, failed
    public var isBusy: Bool {
      self == .starting || self == .waiting || self == .cancelling || self == .loggingOut
    }
  }
  public struct Completion: Equatable, Sendable {
    public enum Result: Equatable, Sendable { case loggedIn, loggedOut }
    public let operationID: UUID
    public let ownerID: UUID
    public let result: Result
  }

  public static let shared = CodexAccountLoginCoordinator(
    service: CodexAppServerClient.shared,
    accountDidChange: { await CodexConnectionController.shared.accountDidChange() },
    accountStatus: { CodexConnectionController.shared.accountStatus })

  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var ownerID: UUID?
  @Published public private(set) var operationID: UUID?
  @Published public private(set) var deviceCode: CodexAppServerDeviceCodeLoginResult?
  @Published public private(set) var message: String?
  @Published public private(set) var isError = false
  @Published public private(set) var completion: Completion?

  public var isBusy: Bool { phase.isBusy }
  public var isLoginFlowActive: Bool { isBusy && phase != .loggingOut }

  private let service: any CodexAccountLoginServing
  private let accountDidChange: @MainActor @Sendable () async -> Void
  private let accountStatus: @MainActor @Sendable () -> CodexAppServerAccountStatus?
  private var task: Task<Void, Never>?

  public init(
    service: any CodexAccountLoginServing,
    accountDidChange: @escaping @MainActor @Sendable () async -> Void,
    accountStatus: @escaping @MainActor @Sendable () -> CodexAppServerAccountStatus?
  ) {
    self.service = service
    self.accountDidChange = accountDidChange
    self.accountStatus = accountStatus
  }

  @discardableResult
  public func login(
    owner: UUID, mode: Mode,
    openURL: @escaping @MainActor @Sendable (URL) -> Bool,
    copyDeviceCode: @escaping @MainActor @Sendable (String) -> Void
  ) -> Bool {
    guard !isBusy else { return false }
    let id = begin(owner: owner, phase: .starting)
    message =
      mode == .browser
      ? CoreL10n.text("正在打开 ChatGPT 登录页面…") : CoreL10n.text("正在创建设备码…")
    task = Task { [self] in
      var loginID: String?
      do {
        switch mode {
        case .browser:
          let login = try await service.startChatGPTLogin()
          loginID = login.loginID
          try Task.checkCancellation()
          guard openURL(login.authURL) else {
            await service.cancelLogin(loginID: login.loginID)
            loginID = nil
            try Task.checkCancellation()
            fail(id, message: CoreL10n.text("无法打开 ChatGPT 登录页面，请检查默认浏览器设置。"))
            return
          }
          message = CoreL10n.text("请在浏览器完成登录；完成后此处会自动更新。")
        case .deviceCode:
          let login = try await service.startChatGPTDeviceCodeLogin()
          loginID = login.loginID
          try Task.checkCancellation()
          deviceCode = login
          copyDeviceCode(login.userCode)
          let opened = openURL(login.verificationURL)
          isError = !opened
          message =
            opened
            ? CoreL10n.text("设备码已复制。请在浏览器完成登录。")
            : CoreL10n.text("无法打开 ChatGPT 登录页面，请检查默认浏览器设置。")
        }
        guard operationID == id, let loginID else { return }
        phase = .waiting
        try await service.waitForLoginCompletion(loginID: loginID)
        try Task.checkCancellation()
        await accountDidChange()
        try Task.checkCancellation()
        guard operationID == id else { return }
        guard let account = accountStatus(), account.isAuthenticated,
          account.accountType?.lowercased() == "chatgpt"
        else { throw CodexAppServerError.accountAuthorizationRequired }
        finish(id, owner: owner, result: .loggedIn)
      } catch {
        if let loginID { await service.cancelLogin(loginID: loginID) }
        guard operationID == id else { return }
        if Task.isCancelled || error is CancellationError
          || error as? CodexAppServerError == .cancelled
        {
          deviceCode = nil
          isError = false
          message = CoreL10n.text("登录已取消。")
          phase = .idle
          task = nil
        } else {
          fail(id, message: error.localizedDescription)
        }
      }
    }
    return true
  }

  public func cancelLogin(owner: UUID) {
    guard ownerID == owner, isLoginFlowActive else { return }
    phase = .cancelling
    task?.cancel()
  }

  @discardableResult
  public func logout(owner: UUID) -> Bool {
    guard !isBusy else { return false }
    let id = begin(owner: owner, phase: .loggingOut)
    task = Task { [self] in
      do {
        try await service.logout()
        await accountDidChange()
        guard operationID == id else { return }
        finish(id, owner: owner, result: .loggedOut)
      } catch {
        fail(id, message: error.localizedDescription)
      }
    }
    return true
  }

  func waitForCurrentOperation() async { await task?.value }

  private func begin(owner: UUID, phase: Phase) -> UUID {
    let id = UUID()
    ownerID = owner
    operationID = id
    completion = nil
    deviceCode = nil
    message = nil
    isError = false
    self.phase = phase
    return id
  }

  private func finish(_ id: UUID, owner: UUID, result: Completion.Result) {
    guard operationID == id else { return }
    deviceCode = nil
    isError = false
    message =
      result == .loggedIn
      ? CoreL10n.text("ChatGPT 登录成功，套餐与用量已刷新。") : CoreL10n.text("已退出 ChatGPT 登录。")
    phase = .succeeded
    completion = .init(operationID: id, ownerID: owner, result: result)
    task = nil
  }

  private func fail(_ id: UUID, message: String) {
    guard operationID == id else { return }
    deviceCode = nil
    isError = true
    self.message = message
    phase = .failed
    task = nil
  }
}
