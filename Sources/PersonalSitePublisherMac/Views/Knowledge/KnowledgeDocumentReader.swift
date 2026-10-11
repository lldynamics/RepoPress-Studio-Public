import AppKit
import PublishingKnowledgeCore
import SwiftUI

struct KnowledgeDocumentReader: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let blocks: [KnowledgeDocumentBlock]
  let isLoading: Bool
  let errorMessage: String?
  let highlightedBlockID: Int?
  let highlightTerms: [String]
  let fontSize: Double
  let lineSpacing: Double
  let paragraphSpacing: Double
  let fontFamily: ReaderFontFamily
  let textAlignment: ReaderTextAlignment
  let codeHighlightTheme: ReaderCodeHighlightTheme
  let retry: () -> Void
  let onAnnotateBlock: (KnowledgeDocumentBlock) -> Void
  let onCopyBlockCitation: (KnowledgeDocumentBlock) -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if isLoading {
      ProgressView("正在读取…")
        .accessibilityLabel("正在读取…")
    } else if let errorMessage {
      VStack(alignment: .leading, spacing: 8) {
        Label("正文读取失败", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(WorkbenchTheme.risk)
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
        Button("重新读取", action: retry)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if blocks.isEmpty {
      EmptyStateView(
        title: "没有可显示正文",
        message: "资料已保存，但正文为空。可以检查来源版本或重新导入。",
        systemImage: "doc.text.magnifyingglass",
        density: .inline
      )
    } else {
      LazyVStack(
        alignment: .leading,
        spacing: max(8, normalizedParagraphSpacing * normalizedFontSize)
      ) {
        ForEach(blocks) { block in
          blockView(block)
            .padding(.horizontal, block.id == highlightedBlockID ? 10 : 0)
            .padding(.vertical, block.id == highlightedBlockID ? 7 : 0)
            .background {
              if block.id == highlightedBlockID {
                RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
                  .fill(Color.yellow.opacity(0.13))
                  .overlay {
                    RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
                      .stroke(workbenchAccentColor.opacity(0.45), lineWidth: 1)
                  }
              }
            }
            .accessibilityAddTraits(block.id == highlightedBlockID ? .isSelected : [])
            .contextMenu {
              Button {
                onAnnotateBlock(block)
              } label: {
                Label("将本段添加为笔记…", systemImage: "note.text.badge.plus")
              }
              Button {
                onCopyBlockCitation(block)
              } label: {
                Label("复制本段为引用", systemImage: "quote.opening")
              }
            }
            .id(block.id)
        }
      }
      .tint(workbenchAccentColor)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("正文")
    }
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeDocumentBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 8 : 4)
        .accessibilityHeading(accessibilityHeadingLevel(level))

    case .paragraph:
      readerBodyText(
        block.text,
        isHighlighted: block.id == highlightedBlockID,
        foregroundColor: .labelColor
      )

    case .quote:
      readerBodyText(
        block.text,
        isHighlighted: block.id == highlightedBlockID,
        foregroundColor: .secondaryLabelColor
      )
      .padding(.leading, WorkbenchSpacing.card)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(Color.secondary.opacity(0.45))
          .frame(width: 2)
          .accessibilityHidden(true)
      }
      .accessibilityLabel("引用：\(block.text)")

    case .unorderedListItem:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "circle.fill")
          .font(.system(size: WorkbenchIconSize.bullet))
          .accessibilityHidden(true)
        readerBodyText(
          block.text,
          isHighlighted: block.id == highlightedBlockID,
          foregroundColor: .labelColor
        )
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .orderedListItem(let number):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: number.map { "\($0)." } ?? "•")
          .foregroundStyle(.secondary)
          .frame(minWidth: 20, alignment: .trailing)
          .accessibilityHidden(true)
        readerBodyText(
          block.text,
          isHighlighted: block.id == highlightedBlockID,
          foregroundColor: .labelColor
        )
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .code(let language):
      let palette = ReaderCodePalette.resolve(
        theme: codeHighlightTheme,
        colorScheme: colorScheme
      )
      VStack(alignment: .leading, spacing: 6) {
        if let language {
          Text(language.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.comment)
        }
        codeText(block, language: language)
          .font(.body.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(WorkbenchSpacing.card)
      .background(
        palette.background, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          .stroke(palette.border, lineWidth: 1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("代码块：\(block.text)")

    case .locator:
      Label(block.text, systemImage: "mappin.and.ellipse")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityLabel("原文位置：\(block.text)")

    case .separator:
      Divider()
        .accessibilityHidden(true)
    }
  }

  private func inlineText(
    _ text: String,
    isHighlighted: Bool
  ) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let attributed =
      (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)
    guard isHighlighted else { return Text(attributed) }
    return KnowledgeHighlightedText.highlightedText(
      String(attributed.characters),
      terms: highlightTerms,
      accentColor: workbenchAccentColor
    )
  }

  @ViewBuilder
  private func readerBodyText(
    _ text: String,
    isHighlighted: Bool,
    foregroundColor: NSColor
  ) -> some View {
    if textAlignment == .justified {
      ReaderJustifiedText(
        markdown: text,
        fontFamily: fontFamily,
        fontSize: normalizedFontSize,
        fontWeight: .regular,
        lineHeightMultiple: normalizedLineSpacing,
        foregroundColor: foregroundColor,
        highlightTerms: isHighlighted ? highlightTerms : []
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      inlineText(text, isHighlighted: isHighlighted)
        .font(fontFamily.swiftUIFont(size: normalizedFontSize))
        .lineSpacing(max(0, normalizedFontSize * (normalizedLineSpacing - 1)))
        .foregroundStyle(Color(nsColor: foregroundColor))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func codeText(
    _ block: KnowledgeDocumentBlock,
    language: String?
  ) -> Text {
    if block.id == highlightedBlockID, !highlightTerms.isEmpty {
      return KnowledgeHighlightedText.highlightedText(
        block.text, terms: highlightTerms, accentColor: workbenchAccentColor)
    }
    return Text(
      ReaderCodeSyntaxHighlighter.attributedString(
        block.text,
        language: language,
        theme: codeHighlightTheme,
        colorScheme: colorScheme
      )
    )
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1:
      fontFamily.swiftUIFont(size: max(24, normalizedFontSize * 1.55), weight: .semibold)
    case 2:
      fontFamily.swiftUIFont(size: max(21, normalizedFontSize * 1.32), weight: .semibold)
    case 3:
      fontFamily.swiftUIFont(size: max(18, normalizedFontSize * 1.12), weight: .semibold)
    default: fontFamily.swiftUIFont(size: normalizedFontSize, weight: .semibold)
    }
  }

  private var normalizedFontSize: Double {
    ReaderTypographyConfiguration.normalizedFontSize(fontSize)
  }

  private var normalizedLineSpacing: Double {
    ReaderTypographyConfiguration.normalizedLineSpacing(lineSpacing)
  }

  private var normalizedParagraphSpacing: Double {
    ReaderTypographyConfiguration.normalizedParagraphSpacing(paragraphSpacing)
  }

  private func accessibilityHeadingLevel(_ level: Int) -> AccessibilityHeadingLevel {
    switch level {
    case 1: .h1
    case 2: .h2
    case 3: .h3
    case 4: .h4
    case 5: .h5
    default: .h6
    }
  }
}
