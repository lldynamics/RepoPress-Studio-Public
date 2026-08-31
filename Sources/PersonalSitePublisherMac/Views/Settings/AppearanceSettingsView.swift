import SwiftUI

struct AppearanceSettingsView: View {
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool
  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue
  @AppStorage(WorkbenchAppearanceMode.storageKey)
  private var appearanceModeRawValue = WorkbenchAppearanceMode.system.rawValue
  @AppStorage(WorkbenchInterfaceDensity.storageKey)
  private var interfaceDensityRawValue = WorkbenchInterfaceDensity.comfortable.rawValue
  @State private var showsGlobalFrontMatterPreset = false

  private var selectedPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }

  private var selectedAppearanceMode: WorkbenchAppearanceMode {
    WorkbenchAppearanceMode.resolved(rawValue: appearanceModeRawValue)
  }

  private var selectedInterfaceDensity: WorkbenchInterfaceDensity {
    WorkbenchInterfaceDensity.resolved(rawValue: interfaceDensityRawValue)
  }

  var body: some View {
    Form {
      SettingsSubsectionAnchor(subsection: .appearanceBehavior)
      DefaultRuleGeneralSection(
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch
      )
      SettingsSubsectionAnchor(subsection: .appearanceTheme)
      Section("外观") {
        appearanceSection
      }
      SettingsSubsectionAnchor(subsection: .appearanceLanguage)
      AppLanguageSettingsView(isEmbedded: true)
      SettingsSubsectionAnchor(subsection: .appearanceDefaults)
      globalFrontMatterSection
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .tint(selectedPalette.color)
    .onAppear {
      if accentPaletteRawValue != selectedPalette.rawValue {
        accentPaletteRawValue = selectedPalette.rawValue
      }
      if appearanceModeRawValue != selectedAppearanceMode.rawValue {
        appearanceModeRawValue = selectedAppearanceMode.rawValue
      }
      if interfaceDensityRawValue != selectedInterfaceDensity.rawValue {
        interfaceDensityRawValue = selectedInterfaceDensity.rawValue
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("appearance-settings")
  }

  private var globalFrontMatterSection: some View {
    Section {
      DisclosureGroup(
        String(localized: "全局 Front Matter 预设"),
        isExpanded: $showsGlobalFrontMatterPreset
      ) {
        Text("此预设适用于所有站点的新文章；站点专属的作者、标签、分类和路径仍在“内容与路径”中设置。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        DefaultRuleCustomFrontMatterSection()
          .padding(.top, 4)
      }
      .accessibilityIdentifier("settings-global-front-matter-preset")
    } header: {
      Text("新建文章默认")
    }
  }

  private var appearanceSection: some View {
    VStack(spacing: 0) {
      appearancePreferenceRow(
        title: "外观模式",
        subtitle: "选择应用的主题模式。"
      ) {
        Picker("外观模式", selection: $appearanceModeRawValue) {
          ForEach(WorkbenchAppearanceMode.allCases) { mode in
            Text(mode.title).tag(mode.rawValue)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .frame(width: 300)
        .accessibilityIdentifier("settings-appearance-mode-picker")
      }

      Divider()

      appearancePreferenceRow(
        title: "强调色",
        subtitle: "选择应用中按钮、链接等高亮元素的颜色。"
      ) {
        HStack(spacing: WorkbenchSpacing.card) {
          ForEach(WorkbenchAccentPalette.allCases) { palette in
            accentPaletteButton(palette)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("强调色")
        .accessibilityIdentifier("settings-accent-color-picker")
      }

      Divider()

      appearancePreferenceRow(
        title: "界面密度",
        subtitle: "调整界面控件的紧凑程度。"
      ) {
        Picker("界面密度", selection: $interfaceDensityRawValue) {
          ForEach(WorkbenchInterfaceDensity.allCases) { density in
            Text(density.title).tag(density.rawValue)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .frame(width: 240)
        .accessibilityIdentifier("settings-interface-density-picker")
      }
    }
  }

  @ViewBuilder
  private func appearancePreferenceRow<Content: View>(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkbenchSpacing.page) {
        preferenceLabel(title: title, subtitle: subtitle)
          .frame(width: 220, alignment: .leading)
        Spacer(minLength: WorkbenchSpacing.card)
        content()
      }

      VStack(alignment: .leading, spacing: WorkbenchSpacing.section) {
        preferenceLabel(title: title, subtitle: subtitle)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 18)
  }

  private func preferenceLabel(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.body.weight(.semibold))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func accentPaletteButton(_ palette: WorkbenchAccentPalette) -> some View {
    let isSelected = palette == selectedPalette
    return Button {
      accentPaletteRawValue = palette.rawValue
    } label: {
      Circle()
        .fill(palette.color)
        .frame(width: 26, height: 26)
        .overlay {
          Circle()
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay {
          if isSelected {
            Circle()
              .strokeBorder(palette.color, lineWidth: 2)
              .padding(-4)
          }
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(palette.title)
    .accessibilityLabel(palette.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

enum AppearancePreviewContrast {
  static func foregroundColor(for background: NSColor) -> NSColor {
    guard let color = background.usingColorSpace(.sRGB) else {
      return .white
    }
    let luminance = relativeLuminance(
      red: color.redComponent,
      green: color.greenComponent,
      blue: color.blueComponent
    )
    let whiteContrast = (1.0 + 0.05) / (luminance + 0.05)
    let blackContrast = (luminance + 0.05) / 0.05
    return whiteContrast >= blackContrast ? .white : .black
  }

  private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
    func linearize(_ component: CGFloat) -> CGFloat {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
  }
}
