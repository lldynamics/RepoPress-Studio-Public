import Combine
import Foundation

/// Gives same-content workspace windows a small ordinal while keeping their
/// persistent scene identity out of the user-facing title.
@MainActor
final class WorkspaceWindowTitleRegistry: ObservableObject {
  static let shared = WorkspaceWindowTitleRegistry()

  private struct Registration {
    let windowID: UUID
    let baseTitle: String
    let sequence: UInt64
  }

  @Published private(set) var revision = 0

  private var registrations: [UUID: Registration] = [:]
  private var nextSequence: UInt64 = 0

  func register(windowID: UUID, registrationID: UUID, baseTitle: String) {
    if let registration = registrations[registrationID] {
      guard registration.windowID != windowID || registration.baseTitle != baseTitle else { return }
      registrations[registrationID] = Registration(
        windowID: windowID,
        baseTitle: baseTitle,
        sequence: registration.sequence
      )
    } else {
      nextSequence &+= 1
      registrations[registrationID] = Registration(
        windowID: windowID,
        baseTitle: baseTitle,
        sequence: nextSequence
      )
    }
    revision &+= 1
  }

  func unregister(_ registrationID: UUID) {
    guard registrations.removeValue(forKey: registrationID) != nil else { return }
    revision &+= 1
  }

  func displayTitle(for registrationID: UUID, baseTitle: String) -> String {
    let matchingRegistrations =
      registrations
      .filter { $0.value.baseTitle == baseTitle }
      .sorted { lhs, rhs in
        if lhs.value.sequence != rhs.value.sequence {
          return lhs.value.sequence < rhs.value.sequence
        }
        return lhs.key.uuidString < rhs.key.uuidString
      }

    guard matchingRegistrations.count > 1,
      let index = matchingRegistrations.firstIndex(where: { $0.key == registrationID })
    else { return baseTitle }

    return index == 0 ? baseTitle : "\(baseTitle) \(index + 1)"
  }
}
