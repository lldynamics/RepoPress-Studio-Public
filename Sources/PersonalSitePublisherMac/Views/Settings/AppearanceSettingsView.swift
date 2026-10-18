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
  @AppStorage(WorkbenchTextScalePreference.storageKey)
  private var textScaleRawValue = WorkbenchTextScalePreference.standard.rawValue
  @WorkspaceModuleVisibilityStorage
  private var moduleVisibility

  private var selectedPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }

  private var selectedAppearanceMode: WorkbenchAppearanceMode {
    WorkbenchAppearanceMode.resolved(rawValue: appearanceModeRawValue)
  }

  private var selectedInterfaceDensity: WorkbenchInterfaceDensity {
    WorkbenchInterfaceDensity.resolved(rawValue: interfaceDensityRawValue)
  }

  private var selectedTextScale: WorkbenchTextScalePreference {
    WorkbenchTextScalePreference.resolved(rawValue: textScaleRawValue)
  }

  var body: some View {
    Form {
      DefaultRuleGeneralSection(
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch,
        subsectionAnchor: .appearanceBehavior
      )
      Section {
        appearanceSection
      } header: {
        Text("外观")
          .settingsSubsectionAnchor(.appearanceTheme)
      }
      WorkspaceModuleSettingsSection(visibility: $moduleVisibility)
    }
    .formStyle(.grouped)
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
      if textScaleRawValue != selectedTextScale.rawValue {
        textScaleRawValue = selectedTextScale.rawValue
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("appearance-settings")
  }

  private var appearanceSection: some View {
    VStack(spacing: 0) {
      appearancePreferenceRow(
        title: "外观模式",
        subtitle: "选择应用的主题模式。"
      ) {
        appearanceModePicker()
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
        title: "界面字号",
        subtitle: "调整工作台界面文字；编辑器正文请在编辑设置中单独调整。"
      ) {
        textScalePicker()
      }

      Divider()

      appearancePreferenceRow(
        title: "界面密度",
        subtitle: "调整界面控件的紧凑程度。"
      ) {
        interfaceDensityPicker()
      }
    }
  }

  @ViewBuilder
  private func appearanceModePicker() -> some View {
    if selectedTextScale == .standard {
      Picker("外观模式", selection: $appearanceModeRawValue) {
        appearanceModeOptions()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.regular)
      .frame(width: 300)
      .accessibilityLabel("外观模式")
      .accessibilityValue(selectedAppearanceMode.title)
      .accessibilityIdentifier("settings-appearance-mode-picker")
    } else {
      WorkbenchScaledMenuPicker(
        title: String(localized: "外观模式"),
        selection: $appearanceModeRawValue,
        options: WorkbenchAppearanceMode.allCases.map {
          .init(value: $0.rawValue, title: $0.title)
        },
        accessibilityIdentifier: "settings-appearance-mode-picker"
      )
      .frame(minWidth: 170, alignment: .leading)
    }
  }

  @ViewBuilder
  private func appearanceModeOptions() -> some View {
    ForEach(WorkbenchAppearanceMode.allCases) { mode in
      Text(mode.title).tag(mode.rawValue)
    }
  }

  private func textScalePicker() -> some View {
    WorkbenchScaledMenuPicker(
      title: String(localized: "界面字号"),
      selection: $textScaleRawValue,
      options: WorkbenchTextScalePreference.allCases.map {
        .init(value: $0.rawValue, title: $0.title)
      },
      accessibilityIdentifier: "settings-interface-text-scale-picker"
    )
    .frame(minWidth: 170, alignment: .leading)
  }

  @ViewBuilder
  private func interfaceDensityPicker() -> some View {
    if selectedTextScale == .standard {
      Picker("界面密度", selection: $interfaceDensityRawValue) {
        interfaceDensityOptions()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.regular)
      .frame(width: 240)
      .accessibilityLabel("界面密度")
      .accessibilityValue(selectedInterfaceDensity.title)
      .accessibilityIdentifier("settings-interface-density-picker")
    } else {
      WorkbenchScaledMenuPicker(
        title: String(localized: "界面密度"),
        selection: $interfaceDensityRawValue,
        options: WorkbenchInterfaceDensity.allCases.map {
          .init(value: $0.rawValue, title: $0.title)
        },
        accessibilityIdentifier: "settings-interface-density-picker"
      )
      .frame(minWidth: 170, alignment: .leading)
    }
  }

  @ViewBuilder
  private func interfaceDensityOptions() -> some View {
    ForEach(WorkbenchInterfaceDensity.allCases) { density in
      Text(density.title).tag(density.rawValue)
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

      VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
        preferenceLabel(title: title, subtitle: subtitle)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, WorkbenchSpacing.content)
  }

  private func preferenceLabel(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.workbenchBody.weight(.semibold))
      Text(subtitle)
        .font(.workbenchBody)
        .foregroundStyle(.workbenchSecondary)
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
