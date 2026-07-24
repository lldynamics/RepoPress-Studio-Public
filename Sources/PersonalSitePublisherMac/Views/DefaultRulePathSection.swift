import PublishingWorkbenchCore
import SwiftUI

struct DefaultRulePathSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let shouldFocusPaths: Bool
  let navigationRequestID: UUID
  @FocusState private var focusedPathField: DefaultRulePathField?

  var body: some View {
    TextField("内容根目录", text: activeProfileBinding.contentRoot)
      .focused($focusedPathField, equals: .contentRoot)
      .accessibilityLabel("内容根目录")
      .accessibilityValue(activeProfile.contentRoot)

    TextField("资源根目录", text: activeProfileBinding.assetRoot)
      .accessibilityLabel("资源根目录")
      .accessibilityValue(activeProfile.assetRoot)

    TextField("Markdown 路径模板", text: activeProfileBinding.markdownPathPattern)
      .accessibilityLabel("Markdown 路径模板")
      .accessibilityValue(activeProfile.markdownPathPattern)

    TextField("图片路径模板", text: activeProfileBinding.imagePathPattern)
      .accessibilityLabel("图片路径模板")
      .accessibilityValue(activeProfile.imagePathPattern)

    TextField("公开图片路径模板", text: activeProfileBinding.publicImagePathPattern)
      .accessibilityLabel("公开图片路径模板")
      .accessibilityValue(activeProfile.publicImagePathPattern)
      .task(id: navigationRequestID) {
        guard shouldFocusPaths else { return }
        focusedPathField = .contentRoot
      }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }
}

private enum DefaultRulePathField: Hashable {
  case contentRoot
}
