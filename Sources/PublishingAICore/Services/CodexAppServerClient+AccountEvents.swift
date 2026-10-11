import Foundation

struct CodexAppServerAccountEventState: Sendable {
  var revision: UInt64 = 0
  var sequence: UInt64 = 0
  var subscribers: [UUID: AsyncStream<CodexAppServerAccountEvent>.Continuation] = [:]
}

extension CodexAppServerClient {
  /// Observes the existing connection without starting a process or granting permission to send.
  /// A revision accompanies every event so dropping an older buffered invalidation is safe.
  public func accountEvents() -> AsyncStream<CodexAppServerAccountEvent> {
    let id = UUID()
    let pair = AsyncStream<CodexAppServerAccountEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeAccountSubscriber(id) }
    }
    accountEventState.subscribers[id] = pair.continuation
    return pair.stream
  }

  var accountEventSubscriberCount: Int { accountEventState.subscribers.count }

  private func removeAccountSubscriber(_ id: UUID) {
    accountEventState.subscribers.removeValue(forKey: id)
  }

  func handleAccountNotification(method: String, params: CodexAppServerJSONValue?) -> Bool {
    switch method {
    case "account/updated":
      if params?.objectValue != nil { publishAccountInvalidation(.accountChanged) }
      return true
    case "account/rateLimits/updated":
      guard let params, params["rateLimits"]?.objectValue != nil else { return true }
      publishAccountEvent(.rateLimitsUpdated(parseRateLimits(params)))
      return true
    default:
      return false
    }
  }

  func publishAccountInvalidation(_ kind: CodexAppServerAccountEvent.Kind) {
    accountEventState.revision &+= 1
    publishAccountEvent(kind)
  }

  private func publishAccountEvent(_ kind: CodexAppServerAccountEvent.Kind) {
    accountEventState.sequence &+= 1
    let event = CodexAppServerAccountEvent(
      generation: transportGeneration, accountRevision: accountEventState.revision,
      sequence: accountEventState.sequence, kind: kind)
    for continuation in accountEventState.subscribers.values { continuation.yield(event) }
  }

  func parseAccountStatus(_ value: CodexAppServerJSONValue) -> CodexAppServerAccountStatus {
    let root = value.objectValue ?? [:]
    let accountValue = root["account"]
    let account = accountValue?.objectValue ?? (accountValue == nil ? root : [:])
    let accountID = firstString(in: account, keys: ["id", "accountId", "accountID"])
    let accountType = firstString(in: account, keys: ["type", "accountType"])
    let email = firstString(in: account, keys: ["email", "emailAddress"])
    let planType = firstString(in: account, keys: ["planType", "plan", "subscription"])
    let explicitAuthenticated =
      root["authenticated"]?.boolValue
      ?? root["isAuthenticated"]?.boolValue
      ?? account["authenticated"]?.boolValue
      ?? account["isAuthenticated"]?.boolValue

    let hasAccountData =
      accountID != nil || email != nil || planType != nil
      || (accountType != nil && accountType != "apiKey")
    let isAccountObjectPresent =
      (accountValue?.objectValue != nil) && !(accountValue?.objectValue?.isEmpty ?? true)

    let authenticated: Bool
    if let explicitAuthenticated {
      authenticated = explicitAuthenticated
    } else if isAccountObjectPresent && hasAccountData {
      authenticated = true
    } else if let requiresAuth = root["requiresOpenaiAuth"]?.boolValue
      ?? root["requiresAuth"]?.boolValue
    {
      authenticated = !requiresAuth
    } else {
      authenticated = hasAccountData
    }

    return CodexAppServerAccountStatus(
      isAuthenticated: authenticated,
      accountID: accountID,
      accountType: accountType,
      email: email,
      planType: planType
    )
  }

  func parseRateLimits(_ value: CodexAppServerJSONValue) -> CodexAppServerRateLimits {
    let root = value.objectValue ?? [:]
    let object = root["rateLimits"]?.objectValue ?? root
    let primary = parseRateLimitWindow(object["primary"] ?? object["primaryWindow"])
    let secondary = parseRateLimitWindow(object["secondary"] ?? object["secondaryWindow"])
    let credits =
      object["creditsRemaining"]?.doubleValue
      ?? object["credits"]?.objectValue?["remaining"]?.doubleValue
    let planType = firstString(in: object, keys: ["planType", "plan"])
    return CodexAppServerRateLimits(
      primary: primary,
      secondary: secondary,
      creditsRemaining: credits,
      planType: planType
    )
  }
}
