enum AccessibleStatusSeverity {
  case info
  case success
  case warning
  case error
}

enum AccessibleStatusAnnouncementPriority: Equatable {
  case low
  case medium
  case high
}

struct AccessibleStatusAnnouncementPolicy: Equatable {
  let shouldAnnounce: Bool
  let shouldMoveAccessibilityFocus: Bool
  let priority: AccessibleStatusAnnouncementPriority?

  init(
    severity: AccessibleStatusSeverity,
    announcesNonUrgentStatus: Bool,
    movesAccessibilityFocusForUrgentStatus: Bool = true
  ) {
    switch severity {
    case .info:
      shouldAnnounce = announcesNonUrgentStatus
      shouldMoveAccessibilityFocus = false
      priority = announcesNonUrgentStatus ? .low : nil
    case .success:
      shouldAnnounce = announcesNonUrgentStatus
      shouldMoveAccessibilityFocus = false
      priority = announcesNonUrgentStatus ? .medium : nil
    case .warning, .error:
      shouldAnnounce = true
      shouldMoveAccessibilityFocus = movesAccessibilityFocusForUrgentStatus
      priority = .high
    }
  }
}
