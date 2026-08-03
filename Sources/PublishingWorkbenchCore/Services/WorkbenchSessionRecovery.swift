import Foundation

/// The small amount of state needed to distinguish a clean quit from a
/// process that disappeared before `applicationWillTerminate` could run.
/// It contains no workspace content or credentials.
public struct WorkbenchSessionLaunchState: Equatable, Sendable {
  public let hadUncleanPreviousSession: Bool
  public let safeModeWasRequested: Bool
  public let startedAt: Date

  public init(
    hadUncleanPreviousSession: Bool,
    safeModeWasRequested: Bool,
    startedAt: Date
  ) {
    self.hadUncleanPreviousSession = hadUncleanPreviousSession
    self.safeModeWasRequested = safeModeWasRequested
    self.startedAt = startedAt
  }
}

/// Persists only launch lifecycle markers. A clean marker is written after
/// all pending workspace writes have succeeded; a missing clean marker on the
/// next launch is therefore a useful crash/force-quit signal.
public final class WorkbenchSessionRecovery {
  @MainActor public static let shared = WorkbenchSessionRecovery()

  private let defaults: UserDefaults
  private let markerKey: String
  private let cleanKey: String
  private let startedAtKey: String
  private let safeModeKey: String

  public init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "PersonalSitePublisherMac.session"
  ) {
    self.defaults = defaults
    markerKey = "\(keyPrefix).hasStarted"
    cleanKey = "\(keyPrefix).didExitCleanly"
    startedAtKey = "\(keyPrefix).startedAt"
    safeModeKey = "\(keyPrefix).safeModeNextLaunch"
  }

  public func beginLaunch(
    safeModeRequestedByEnvironment: Bool = false
  ) -> WorkbenchSessionLaunchState {
    let hadMarker = defaults.bool(forKey: markerKey)
    let hadUncleanPreviousSession = hadMarker && !defaults.bool(forKey: cleanKey)
    let safeModeWasRequested = safeModeRequestedByEnvironment
      || defaults.bool(forKey: safeModeKey)
    let startedAt = Date()

    defaults.set(true, forKey: markerKey)
    defaults.set(false, forKey: cleanKey)
    defaults.set(startedAt.timeIntervalSince1970, forKey: startedAtKey)
    defaults.removeObject(forKey: safeModeKey)

    return WorkbenchSessionLaunchState(
      hadUncleanPreviousSession: hadUncleanPreviousSession,
      safeModeWasRequested: safeModeWasRequested,
      startedAt: startedAt
    )
  }

  public func markCleanExit() {
    guard defaults.bool(forKey: markerKey) else { return }
    defaults.set(true, forKey: cleanKey)
  }

  public func requestSafeModeOnNextLaunch() {
    defaults.set(true, forKey: safeModeKey)
  }

  public func clearSafeModeRequest() {
    defaults.removeObject(forKey: safeModeKey)
  }
}
