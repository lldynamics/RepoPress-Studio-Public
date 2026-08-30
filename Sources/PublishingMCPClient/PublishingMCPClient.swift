import Foundation

/// Public façade around the isolated stdio lifecycle. It intentionally exports
/// checked discovery while keeping raw calls and SDK transport/session types
/// behind the module boundary.
public actor PublishingMCPClient {
  public nonisolated let configuration: PublishingMCPSourceConfiguration
  private let sessionFactory: PublishingMCPClientSessionFactory
  private var session: (any PublishingMCPClientSession)?
  private var connectionTask: Task<any PublishingMCPClientSession, Error>?
  private var connectionGeneration: UInt64 = 0

  public init(configuration: PublishingMCPSourceConfiguration) {
    self.configuration = configuration
    self.sessionFactory = { configuration in
      PublishingMCPStdioSession(configuration: configuration)
    }
  }

  init(
    configuration: PublishingMCPSourceConfiguration,
    sessionFactory: @escaping PublishingMCPClientSessionFactory
  ) {
    self.configuration = configuration
    self.sessionFactory = sessionFactory
  }

  deinit {
    let session = session
    let connectionTask = connectionTask
    connectionTask?.cancel()
    Task {
      if let connectionTask, let pendingSession = try? await connectionTask.value {
        await pendingSession.close()
      }
      await session?.close()
    }
  }

  public func discoverTools() async throws -> [PublishingMCPDiscoveredTool] {
    try await ensureConnected()
    guard let activeSession = session else { throw PublishingMCPClientError.connectionFailed }
    do {
      return try await activeSession.listTools()
    } catch {
      await invalidateIfCurrent(activeSession)
      throw error
    }
  }

  func call(
    remoteToolName: String,
    argumentsJSON: String
  ) async throws -> PublishingMCPCallResult {
    try await ensureConnected()
    guard let activeSession = session else { throw PublishingMCPClientError.connectionFailed }
    do {
      return try await activeSession.call(
        remoteToolName: remoteToolName,
        argumentsJSON: argumentsJSON
      )
    } catch {
      await invalidateIfCurrent(activeSession)
      throw error
    }
  }

  public func disconnect() async {
    connectionGeneration &+= 1
    let connectionTask = connectionTask
    let activeSession = session
    self.connectionTask = nil
    self.session = nil
    connectionTask?.cancel()
    if let connectionTask, let pendingSession = try? await connectionTask.value {
      await pendingSession.close()
    }
    await activeSession?.close()
  }

  private func ensureConnected() async throws {
    guard session == nil else { return }
    let generation = connectionGeneration
    let task: Task<any PublishingMCPClientSession, Error>
    if let connectionTask {
      task = connectionTask
    } else {
      let configuration = configuration
      let sessionFactory = sessionFactory
      task = Task {
        try Task.checkCancellation()
        let session = await sessionFactory(configuration)
        do {
          try Task.checkCancellation()
          try await session.connect()
          try Task.checkCancellation()
          return session
        } catch {
          await session.close()
          throw error
        }
      }
      connectionTask = task
    }

    do {
      let connectedSession = try await task.value
      guard generation == connectionGeneration else {
        await connectedSession.close()
        throw CancellationError()
      }
      session = connectedSession
      connectionTask = nil
    } catch {
      if generation == connectionGeneration {
        connectionTask = nil
      }
      throw error
    }
  }

  private func invalidateIfCurrent(
    _ failedSession: any PublishingMCPClientSession
  ) async {
    if let activeSession = session, activeSession === failedSession {
      session = nil
    }
    await failedSession.close()
  }
}
