import Foundation

extension CodexAppServerClient {
  public func startChatGPTLogin() async throws -> CodexAppServerLoginResult {
    let result = try await startManagedLogin(
      params: .object([
        "appBrand": .string("chatgpt"), "type": .string("chatgpt"),
        "useHostedLoginSuccessPage": .bool(true),
      ]))
    guard let rawURL = firstString(in: result.object, keys: ["authUrl", "authURL", "url"]),
      let url = Self.validatedLoginURL(rawURL)
    else {
      await cancelLogin(loginID: result.loginID)
      throw CodexAppServerError.invalidResponse
    }
    return CodexAppServerLoginResult(loginID: result.loginID, authURL: url)
  }

  public func startChatGPTDeviceCodeLogin() async throws -> CodexAppServerDeviceCodeLoginResult {
    let result = try await startManagedLogin(
      params: .object(["type": .string("chatgptDeviceCode")]))
    guard
      let rawURL = firstString(
        in: result.object, keys: ["verificationUrl", "verificationURL", "verificationUri", "url"]),
      let url = Self.validatedLoginURL(rawURL),
      let userCode = firstString(in: result.object, keys: ["userCode", "code"]), !userCode.isEmpty
    else {
      await cancelLogin(loginID: result.loginID)
      throw CodexAppServerError.invalidResponse
    }
    return CodexAppServerDeviceCodeLoginResult(
      loginID: result.loginID, verificationURL: url, userCode: userCode)
  }

  private func startManagedLogin(params: CodexAppServerJSONValue) async throws -> (
    loginID: String, object: [String: CodexAppServerJSONValue]
  ) {
    activeUserOperations += 1
    defer { endUserOperation() }
    let attemptID = UUID()
    do {
      let value = try await request(
        method: "account/login/start", params: params, loginAttemptID: attemptID)
      guard !Task.isCancelled else { throw CodexAppServerError.cancelled }
      guard let entry = loginState.starts.first(where: { $0.value.attemptID == attemptID }) else {
        throw transportEnded ? transportEndError : CodexAppServerError.invalidResponse
      }
      guard !Task.isCancelled, !entry.value.cancelled else { throw CodexAppServerError.cancelled }
      guard entry.value.generation == transportGeneration, !transportEnded else {
        throw transportEndError
      }
      guard let root = value.objectValue else { throw CodexAppServerError.invalidResponse }
      let object = root["login"]?.objectValue ?? root
      guard let loginID = firstString(in: object, keys: ["loginId", "loginID", "id"]),
        !loginID.isEmpty
      else { throw CodexAppServerError.invalidResponse }
      removeLoginStart(requestID: entry.key)
      loginState.forgetTerminal(loginID)
      loginState.generations[loginID] = entry.value.generation
      if let early = loginState.earlyOutcomes.removeValue(forKey: loginID),
        early.generation == entry.value.generation
      {
        loginState.outcomes[loginID] = early.outcome
      }
      scheduleLoginExpiry(loginID: loginID)
      if case .failed(let error) = loginState.outcomes[loginID] {
        retireLogin(loginID: loginID, error: error)
      }
      return (loginID, object)
    } catch {
      if let entry = loginState.starts.first(where: { $0.value.attemptID == attemptID }) {
        cancelLoginStart(requestID: entry.key)
      }
      throw error
    }
  }

  public func waitForLoginCompletion(loginID: String) async throws {
    activeUserOperations += 1
    defer { endUserOperation() }
    if Task.isCancelled {
      await cancelLogin(loginID: loginID)
      throw CodexAppServerError.cancelled
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if let error = loginState.terminalErrors[loginID] {
          continuation.resume(throwing: error)
        } else if loginState.generations[loginID] != transportGeneration || transportEnded {
          continuation.resume(
            throwing: transportEnded ? transportEndError : CodexAppServerError.invalidResponse)
        } else if let outcome = loginState.outcomes.removeValue(forKey: loginID) {
          retireLogin(loginID: loginID, error: .invalidResponse)
          resumeLoginWaiter(continuation, with: outcome)
        } else if loginState.waiters[loginID] != nil {
          continuation.resume(throwing: CodexAppServerError.invalidResponse)
        } else {
          loginState.waiters[loginID] = continuation
        }
      }
    } onCancel: {
      Task { [weak self] in await self?.cancelLogin(loginID: loginID) }
    }
  }

  public func cancelLogin(loginID: String) async {
    activeUserOperations += 1
    defer { endUserOperation() }
    if let cleanup = loginState.cancellations[loginID],
      loginState.generations[loginID] == nil
        || loginState.generations[loginID] == cleanup.generation
    {
      await cleanup.task.value
      return
    }
    guard let generation = loginState.generations[loginID] else { return }
    let shouldCancelRemotely = loginState.outcomes[loginID] == nil
    let cleanup =
      shouldCancelRemotely ? loginCancellationTask(loginID: loginID, generation: generation) : nil
    let waiter = loginState.waiters.removeValue(forKey: loginID)
    retireLogin(loginID: loginID, error: .cancelled)
    waiter?.resume(throwing: CodexAppServerError.cancelled)
    await cleanup?.value
  }

  func prepareLoginStart(attemptID: UUID, requestID: Int, generation: Int) {
    loginState.starts[requestID] = .init(attemptID: attemptID, generation: generation)
  }

  func cancelLoginStart(requestID: Int) {
    guard var start = loginState.starts[requestID], !start.cancelled else { return }
    start.cancelled = true
    loginState.starts[requestID] = start
    if let loginID = start.loginID {
      removeLoginStart(requestID: requestID)
      loginState.earlyOutcomes.removeValue(forKey: loginID)
      loginState.rememberTerminal(.cancelled, loginID: loginID)
      Task { await self.sendLoginCancellation(loginID: loginID, generation: start.generation) }
    } else {
      let timeout = loginTimeout
      loginState.startExpiryTasks[requestID] = Task { [weak self] in
        do { try await Task.sleep(for: timeout) } catch { return }
        await self?.removeLoginStart(requestID: requestID)
      }
      let cancelled = loginState.starts.filter { $0.value.cancelled }.keys.sorted()
      for id in cancelled.prefix(
        max(0, cancelled.count - CodexAppServerLoginState.maximumRetainedRecords))
      {
        removeLoginStart(requestID: id)
      }
    }
  }

  /// Correlate a late start response before the generic RPC continuation is
  /// discarded. Cleanup is bound to its existing process, never a new startup.
  func handleLoginStartResponse(_ envelope: CodexAppServerRPCEnvelope) {
    guard let requestID = envelope.id, var start = loginState.starts[requestID] else { return }
    guard envelope.error == nil, let root = envelope.result?.objectValue,
      let loginID = firstString(
        in: root["login"]?.objectValue ?? root, keys: ["loginId", "loginID", "id"]),
      !loginID.isEmpty
    else {
      removeLoginStart(requestID: requestID)
      return
    }
    start.loginID = loginID
    loginState.starts[requestID] = start
    if start.cancelled {
      removeLoginStart(requestID: requestID)
      loginState.earlyOutcomes.removeValue(forKey: loginID)
      loginState.rememberTerminal(.cancelled, loginID: loginID)
      Task { await self.sendLoginCancellation(loginID: loginID, generation: start.generation) }
    }
  }

  private func removeLoginStart(requestID: Int) {
    loginState.starts.removeValue(forKey: requestID)
    loginState.startExpiryTasks.removeValue(forKey: requestID)?.cancel()
  }

  func finishLogin(loginID: String, outcome: CodexAppServerLoginState.Outcome) {
    guard loginState.terminalErrors[loginID] == nil else { return }
    guard loginState.generations[loginID] == transportGeneration else {
      guard
        loginState.starts.values.contains(where: {
          !$0.cancelled && $0.generation == transportGeneration
        }),
        loginState.earlyOutcomes.count < CodexAppServerLoginState.maximumRetainedRecords
      else { return }
      loginState.earlyOutcomes[loginID] = .init(generation: transportGeneration, outcome: outcome)
      if loginState.expiryTasks[loginID] == nil { scheduleLoginExpiry(loginID: loginID) }
      return
    }
    if let waiter = loginState.waiters.removeValue(forKey: loginID) {
      retireLogin(loginID: loginID, error: .invalidResponse)
      resumeLoginWaiter(waiter, with: outcome)
      endLoginActivity()
    } else {
      if case .failed(let error) = outcome {
        retireLogin(loginID: loginID, error: error)
        endLoginActivity()
      } else {
        loginState.outcomes[loginID] = outcome
      }
    }
  }

  private func scheduleLoginExpiry(loginID: String) {
    loginState.expiryTasks.removeValue(forKey: loginID)?.cancel()
    let timerID = UUID()
    let generation = transportGeneration
    loginState.expiryTokens[loginID] = timerID
    let timeout = loginTimeout
    loginState.expiryTasks[loginID] = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
        try Task.checkCancellation()
      } catch { return }
      await self?.expireLogin(loginID: loginID, timerID: timerID, generation: generation)
    }
  }

  func expireLogin(loginID: String, timerID: UUID, generation: Int) async {
    guard loginState.expiryTokens[loginID] == timerID, transportGeneration == generation else {
      return
    }
    activeUserOperations += 1
    defer { endUserOperation() }
    let loginGeneration = loginState.generations[loginID]
    let shouldCancel = loginGeneration != nil && loginState.outcomes[loginID] == nil
    let cleanup =
      shouldCancel
      ? loginCancellationTask(loginID: loginID, generation: loginGeneration ?? generation) : nil
    let waiter = loginState.waiters.removeValue(forKey: loginID)
    retireLogin(loginID: loginID, error: .loginTimedOut)
    waiter?.resume(throwing: CodexAppServerError.loginTimedOut)
    await cleanup?.value
  }

  private func retireLogin(loginID: String, error: CodexAppServerError) {
    loginState.generations.removeValue(forKey: loginID)
    loginState.outcomes.removeValue(forKey: loginID)
    loginState.earlyOutcomes.removeValue(forKey: loginID)
    loginState.expiryTasks.removeValue(forKey: loginID)?.cancel()
    loginState.expiryTokens.removeValue(forKey: loginID)
    loginState.rememberTerminal(error, loginID: loginID)
  }

  private func sendLoginCancellation(loginID: String, generation: Int) async {
    await loginCancellationTask(loginID: loginID, generation: generation).value
  }

  private func loginCancellationTask(loginID: String, generation: Int) -> Task<Void, Never> {
    if let cleanup = loginState.cancellations[loginID], cleanup.generation == generation {
      return cleanup.task
    }
    let token = UUID()
    // Do not inherit the cancelled caller's task when cleaning up its session.
    let task = Task { [self] in
      defer {
        if loginState.cancellations[loginID]?.token == token {
          loginState.cancellations.removeValue(forKey: loginID)
        }
      }
      guard generation == transportGeneration, !transportEnded else { return }
      activeUserOperations += 1
      defer { endUserOperation() }
      do {
        _ = try await requestWithoutStartup(
          method: "account/login/cancel", params: .object(["loginId": .string(loginID)]))
      } catch {
        // Local termination already happened; remote cleanup is best effort.
      }
    }
    loginState.cancellations[loginID] = .init(generation: generation, token: token, task: task)
    return task
  }

  private func resumeLoginWaiter(
    _ waiter: CheckedContinuation<Void, Error>, with outcome: CodexAppServerLoginState.Outcome
  ) {
    switch outcome {
    case .succeeded: waiter.resume()
    case .failed(let error): waiter.resume(throwing: error)
    }
  }

  func failAllLogins(with error: CodexAppServerError) {
    for id in loginState.generations.keys { loginState.rememberTerminal(error, loginID: id) }
    let waiters = loginState.waiters.values
    let timers = Array(loginState.expiryTasks.values) + Array(loginState.startExpiryTasks.values)
    loginState.waiters.removeAll()
    loginState.generations.removeAll()
    loginState.outcomes.removeAll()
    loginState.earlyOutcomes.removeAll()
    loginState.starts.removeAll()
    loginState.expiryTasks.removeAll()
    loginState.expiryTokens.removeAll()
    loginState.startExpiryTasks.removeAll()
    for timer in timers { timer.cancel() }
    for waiter in waiters { waiter.resume(throwing: error) }
  }

  private func endLoginActivity() {
    // Wake pending replacement when a notification consumes the last waiter.
    activeUserOperations += 1
    endUserOperation()
  }
}
