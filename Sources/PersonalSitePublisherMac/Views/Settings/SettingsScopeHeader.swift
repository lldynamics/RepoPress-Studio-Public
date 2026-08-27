import SwiftUI

/// Shared secondary navigation for settings pages with multiple related scopes.
/// It keeps the control horizontal when there is room and stacks it below the
/// current-scope summary at compact window widths.
struct SettingsScopeHeader<Leading: View, ScopeControl: View>: View {
  let minimumLeadingWidth: CGFloat
  let scopeControlWidth: CGFloat
  private let leading: Leading
  private let scopeControl: ScopeControl

  init(
    minimumLeadingWidth: CGFloat = 0,
    scopeControlWidth: CGFloat = 360,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder scopeControl: () -> ScopeControl
  ) {
    self.minimumLeadingWidth = minimumLeadingWidth
    self.scopeControlWidth = scopeControlWidth
    self.leading = leading()
    self.scopeControl = scopeControl()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: WorkbenchSpacing.section) {
        leading
          .frame(minWidth: minimumLeadingWidth, maxWidth: .infinity, alignment: .leading)

        scopeControl
          .frame(width: scopeControlWidth)
      }

      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        leading
          .frame(maxWidth: .infinity, alignment: .leading)

        scopeControl
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, WorkbenchSpacing.control)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
