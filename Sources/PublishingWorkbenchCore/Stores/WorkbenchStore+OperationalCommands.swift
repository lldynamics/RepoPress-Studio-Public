import Foundation

extension WorkbenchStore {
  @discardableResult
  public func tickRepositoryAndDeploymentPolling(now: Date = Date()) async -> Bool {
    if let operationalPollingTickTask {
      return await operationalPollingTickTask.value
    }

    let requestID = UUID()
    operationalPollingTickRequestID = requestID
    let task = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else { return false }
      return await repositoryDeploymentCoordinator.tickOperationalPolling(store: self, now: now)
    }
    operationalPollingTickTask = task
    let didRun = await task.value
    if operationalPollingTickRequestID == requestID {
      operationalPollingTickTask = nil
      operationalPollingTickRequestID = nil
    }
    return didRun
  }

  /// Registers one active window while keeping exactly one polling heartbeat
  /// for the shared store. Provider requests still obey each profile's saved
  /// minimum interval; the heartbeat only notices when a run becomes due.
  public func startOperationalPolling(clientID: UUID) {
    guard !isSafeMode else { return }
    operationalPollingClientIDs.insert(clientID)
    guard operationalPollingTask == nil else { return }

    operationalPollingGeneration &+= 1
    let generation = operationalPollingGeneration
    operationalPollingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled,
        operationalPollingGeneration == generation,
        !operationalPollingClientIDs.isEmpty
      {
        _ = await tickRepositoryAndDeploymentPolling(now: Date())
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          break
        }
      }
      if operationalPollingGeneration == generation {
        operationalPollingTask = nil
      }
    }
  }

  public func stopOperationalPolling(clientID: UUID) {
    operationalPollingClientIDs.remove(clientID)
    guard operationalPollingClientIDs.isEmpty else { return }
    operationalPollingGeneration &+= 1
    operationalPollingTask?.cancel()
    operationalPollingTask = nil
    operationalPollingTickTask?.cancel()
    operationalPollingTickTask = nil
    operationalPollingTickRequestID = nil
  }

  /// Requests the normal operational check after a local repository write.
  /// The repository and deployment stores apply their configured minimum
  /// intervals, so frequent editor saves collapse into a no-op while an
  /// overdue check still runs once.
  func scheduleDueOperationalRefresh() {
    guard !isSafeMode else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await self.tickRepositoryAndDeploymentPolling(now: Date())
    }
  }

  public func activateQuickHide(reason: String? = nil) {
    privacyProtectionStore.activateQuickHide(reason: reason)
    save()
  }

  public func deactivateQuickHide() {
    privacyProtectionStore.deactivateQuickHide()
    save()
  }

  public var activeDeploymentStatusReadiness: DeploymentStatusProviderReadiness {
    deploymentStore.activeDeploymentStatusReadiness(store: self)
  }
}
