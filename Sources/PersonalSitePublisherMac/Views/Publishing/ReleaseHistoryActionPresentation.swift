import SwiftUI

/// The first visible action in this order is the row's primary action.
/// Disabled actions retain their priority while their original guards remain in effect.
enum ReleaseHistoryActionPresentation: Equatable, Sendable {
  case resumeReview
  case recheckDeployment
  case openRemote
  case copyCommand
  case copyRecovery

  static func primaryAction(
    canResumeReview: Bool,
    canRecheckDeployment: Bool,
    canOpenRemote: Bool,
    canCopyCommand: Bool,
    canCopyRecovery: Bool
  ) -> Self? {
    let candidates: [(Self, Bool)] = [
      (.resumeReview, canResumeReview),
      (.recheckDeployment, canRecheckDeployment),
      (.openRemote, canOpenRemote),
      (.copyCommand, canCopyCommand),
      (.copyRecovery, canCopyRecovery),
    ]
    return candidates.first(where: { $0.1 })?.0
  }
}

struct ReleaseHistoryActionButtonStyle: ViewModifier {
  let action: ReleaseHistoryActionPresentation
  let primaryAction: ReleaseHistoryActionPresentation?

  @ViewBuilder
  func body(content: Content) -> some View {
    if action == primaryAction {
      content
        .buttonStyle(.bordered)
        .controlSize(.small)
    } else {
      content
        .buttonStyle(.link)
        .controlSize(.small)
    }
  }
}
