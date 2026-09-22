import Foundation

public struct DeploymentPollingSettings: Codable, Hashable, Sendable {
  public var isEnabled: Bool
  public var intervalMinutes: Int

  public init(
    isEnabled: Bool = false,
    intervalMinutes: Int = 10
  ) {
    self.isEnabled = isEnabled
    self.intervalMinutes = max(Self.minimumIntervalMinutes, intervalMinutes)
  }

  public static let minimumIntervalMinutes = 5
  public static let maximumIntervalMinutes = 60

  public static var `default`: DeploymentPollingSettings {
    DeploymentPollingSettings()
  }

  public var normalizedIntervalMinutes: Int {
    min(Self.maximumIntervalMinutes, max(Self.minimumIntervalMinutes, intervalMinutes))
  }

  public var interval: TimeInterval {
    TimeInterval(normalizedIntervalMinutes * 60)
  }

  public func nextRunDate(after date: Date) -> Date {
    date.addingTimeInterval(interval)
  }

  public func isDue(lastRunAt: Date?, now: Date) -> Bool {
    guard isEnabled else {
      return false
    }
    guard let lastRunAt else {
      return true
    }
    return now.timeIntervalSince(lastRunAt) >= interval
  }
}
