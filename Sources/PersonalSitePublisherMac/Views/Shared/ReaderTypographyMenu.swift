import SwiftUI

struct ReaderTypographyMenu: View {
  @Binding var fontSize: Double
  @Binding var lineSpacing: Double
  @Binding var paragraphSpacing: Double
  @Binding var fontFamily: ReaderFontFamily
  @Binding var textAlignment: ReaderTextAlignment
  @Binding var codeHighlightTheme: ReaderCodeHighlightTheme
  var readingTheme: Binding<RSSReadingTheme>?
  let accessibilityIdentifier: String

  var body: some View {
    Menu {
      Picker("正文字体", selection: $fontFamily) {
        ForEach(ReaderFontFamily.allCases) { family in
          Text(family.title).tag(family)
        }
      }

      Section("正文字号") {
        Slider(
          value: $fontSize,
          in: ReaderTypographyConfiguration.fontSizeRange,
          step: 1
        ) {
          Text("字号")
        } minimumValueLabel: {
          Text("小")
        } maximumValueLabel: {
          Text("大")
        }
        Text("当前 \(Int(fontSize)) pt")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("行距") {
        Slider(
          value: $lineSpacing,
          in: ReaderTypographyConfiguration.lineSpacingRange,
          step: 0.05
        ) {
          Text("行距")
        } minimumValueLabel: {
          Text("紧")
        } maximumValueLabel: {
          Text("松")
        }
        Text("当前 \(lineSpacing, specifier: "%.2f")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("段间距") {
        Slider(
          value: $paragraphSpacing,
          in: ReaderTypographyConfiguration.paragraphSpacingRange,
          step: 0.05
        ) {
          Text("段间距")
        } minimumValueLabel: {
          Text("紧")
        } maximumValueLabel: {
          Text("松")
        }
        Text("当前 \(paragraphSpacing, specifier: "%.2f") em")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("段落对齐", selection: $textAlignment) {
        ForEach(ReaderTextAlignment.allCases) { alignment in
          Text(alignment.title)
            .tag(alignment)
            .help(alignment.help)
        }
      }

      Picker("代码高亮", selection: $codeHighlightTheme) {
        ForEach(ReaderCodeHighlightTheme.allCases) { theme in
          Text(theme.title).tag(theme)
        }
      }

      if let readingTheme {
        Picker("阅读主题", selection: readingTheme) {
          ForEach(RSSReadingTheme.allCases) { theme in
            Label(theme.title, systemImage: theme.systemImage)
              .tag(theme)
          }
        }
      }
    } label: {
      Label("阅读排版", systemImage: "textformat.size")
    }
    .menuStyle(.borderlessButton)
    .help("调整字体、行距、段间距、对齐和代码高亮")
    .accessibilityLabel("阅读排版设置")
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}
