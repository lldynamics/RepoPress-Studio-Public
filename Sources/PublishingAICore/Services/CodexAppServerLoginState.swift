import Foundation

/// All mutation belongs to the client actor. Early notifications never keep a
/// runtime alive; only claimed, bounded login sessions can delay replacement.
struct CodexAppServerLoginState {
  enum Outcome {
    case succeeded
    case failed(CodexAppServerError)
  }

  struct Start {
    let attemptID: UUID
    let generation: Int
    var cancelled = false
    var loginID: String?
  }

  struct EarlyOutcome {
    let generation: Int
    let outcome: Outcome
  }

  struct Cancellation {
    let generation: Int
    let token: UUID
    let task: Task<Void, Never>
  }

  static let maximumRetainedRecords = 64
  var starts: [Int: Start] = [:]
  var startExpiryTasks: [Int: Task<Void, Never>] = [:]
  var generations: [String: Int] = [:]
  var outcomes: [String: Outcome] = [:]
  var earlyOutcomes: [String: EarlyOutcome] = [:]
  var waiters: [String: CheckedContinuation<Void, Error>] = [:]
  var expiryTasks: [String: Task<Void, Never>] = [:]
  var expiryTokens: [String: UUID] = [:]
  var cancellations: [String: Cancellation] = [:]
  var terminalErrors: [String: CodexAppServerError] = [:]
  var terminalOrder: [String] = []

  var hasBlockingSessions: Bool { !generations.isEmpty || !waiters.isEmpty }

  mutating func rememberTerminal(_ error: CodexAppServerError, loginID: String) {
    terminalOrder.removeAll { $0 == loginID }
    terminalOrder.append(loginID)
    terminalErrors[loginID] = error
    while terminalOrder.count > Self.maximumRetainedRecords {
      terminalErrors.removeValue(forKey: terminalOrder.removeFirst())
    }
  }

  mutating func forgetTerminal(_ loginID: String) {
    terminalErrors.removeValue(forKey: loginID)
    terminalOrder.removeAll { $0 == loginID }
  }
}
