import PublishingWorkbenchCore
import SwiftUI

struct DefaultRulePathSection: View {
  let activeProfileBinding: Binding<SiteProfile>

  var body: some View {
    Section("路径规则") {
      TextField("Content root", text: activeProfileBinding.contentRoot)
        .accessibilityLabel("Content root")
        .accessibilityValue(activeProfile.contentRoot)

      TextField("Asset root", text: activeProfileBinding.assetRoot)
        .accessibilityLabel("Asset root")
        .accessibilityValue(activeProfile.assetRoot)

      TextField("Markdown path pattern", text: activeProfileBinding.markdownPathPattern)
        .accessibilityLabel("Markdown path pattern")
        .accessibilityValue(activeProfile.markdownPathPattern)

      TextField("Image path pattern", text: activeProfileBinding.imagePathPattern)
        .accessibilityLabel("Image path pattern")
        .accessibilityValue(activeProfile.imagePathPattern)

      TextField("Public image path pattern", text: activeProfileBinding.publicImagePathPattern)
        .accessibilityLabel("Public image path pattern")
        .accessibilityValue(activeProfile.publicImagePathPattern)
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }
}
