import SwiftUI

private enum WorkspaceTaskThemeTitleH1Override: Hashable {
  case automatic
  case providesTitleH1
  case doesNotProvideTitleH1

  init(_ value: Bool?) {
    switch value {
    case true: self = .providesTitleH1
    case false: self = .doesNotProvideTitleH1
    case nil: self = .automatic
    }
  }

  var value: Bool? {
    switch self {
    case .automatic: return nil
    case .providesTitleH1: return true
    case .doesNotProvideTitleH1: return false
    }
  }
}

struct WorkspaceTaskSEOPreferenceControls: View {
  @Binding var themeProvidesTitleH1: Bool?
  @Binding var duplicateTitleWarning: Bool
  @Binding var defaultSocialImagePath: String
  @Binding var defaultSocialImageAltText: String
  @Binding var noIndividualImage: Bool
  let resolutionName: String
  let resolutionSourceName: String

  var body: some View {
    Divider()

    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      Picker(
        "主题页面 H1",
        selection: Binding(
          get: { WorkspaceTaskThemeTitleH1Override(themeProvidesTitleH1) },
          set: { themeProvidesTitleH1 = $0.value }
        )
      ) {
        Text("自动检查本地模板").tag(WorkspaceTaskThemeTitleH1Override.automatic)
        Text("主题提供 H1").tag(WorkspaceTaskThemeTitleH1Override.providesTitleH1)
        Text("主题不提供 H1").tag(WorkspaceTaskThemeTitleH1Override.doesNotProvideTitleH1)
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("seo-theme-title-h1-policy")

      Text(
        "当前判断：\(resolutionName) · \(resolutionSourceName)"
      )
      .font(.workbenchMetadata)
      .foregroundStyle(.workbenchSecondary)
      .fixedSize(horizontal: false, vertical: true)

      Toggle(
        "正文 H1 与标题重复时提示",
        isOn: $duplicateTitleWarning
      )
      .controlSize(.small)
      .accessibilityIdentifier("seo-duplicate-title-warning-policy")

      TextField(
        "站点默认分享图路径",
        text: $defaultSocialImagePath
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("站点默认分享图路径")
      .accessibilityIdentifier("seo-site-default-image-path")

      TextField(
        "站点默认分享图 Alt",
        text: $defaultSocialImageAltText
      )
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("站点默认分享图 Alt")
      .accessibilityIdentifier("seo-site-default-image-alt")

      Toggle(
        "本文不单独配图",
        isOn: $noIndividualImage
      )
      .controlSize(.small)
      .help("记录本文的检查偏好；已有本文封面仍优先，站点或主题默认图也不会因此移除。")
      .accessibilityIdentifier("seo-article-no-individual-image")

      Text("这些设置用于 RepoPress 的 SEO 检查和预览，不会写入本文 Front Matter；主题实际输出请在发布后确认。")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct WorkspaceTaskSEOSocialImageSummary: View {
  let value: String
  let warning: String?
  let sourceName: String

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      InspectorStatRow(title: "图片", value: value, systemImage: "photo")
        .foregroundStyle(warning == nil ? Color.primary : WorkbenchTheme.warning)
      if let warning {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.workbenchMetadata)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .help(warning)
          .accessibilityIdentifier("seo-social-image-size-warning")
      }
      Text("图片来源：\(sourceName)")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
