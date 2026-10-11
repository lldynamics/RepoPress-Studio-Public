import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// Both columns share each row's height and one vertical scroll position.
/// Long paragraphs wrap rather than introducing independently scrolling panes.
struct DraftVersionAlignedBodyView: View {
  let rows: [DraftVersionAlignedRow]
  let changesOnly: Bool
  let availableWidth: CGFloat

  private var isSideBySide: Bool { availableWidth >= 760 }
  private var visibleRows: [DraftVersionAlignedRow] {
    changesOnly ? rows.filter(\.hasChanges) : rows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("正文差异", systemImage: "doc.text.magnifyingglass")
        .font(.headline)
      Text("绿色加号表示新增，红色减号表示删除；突出显示具体字词变化。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if visibleRows.isEmpty {
        Text("正文没有变化")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          if isSideBySide {
            HStack(spacing: 0) {
              paneHeading("旧版（左侧）")
              Divider()
              paneHeading("新版（右侧）")
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
          }
          LazyVStack(spacing: 0) {
            ForEach(visibleRows) { row in
              alignedRow(row)
              Divider()
            }
          }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        .overlay {
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
            .stroke(.separator, lineWidth: 1)
        }
        .accessibilityIdentifier(
          isSideBySide ? "draft-version-side-by-side" : "draft-version-stacked"
        )
      }
    }
  }

  private func paneHeading(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .padding(WorkbenchSpacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.35))
  }

  @ViewBuilder
  private func alignedRow(_ row: DraftVersionAlignedRow) -> some View {
    if isSideBySide {
      HStack(alignment: .top, spacing: 0) {
        DraftVersionAlignedLineView(line: row.previous, isPrevious: true)
          .frame(width: (availableWidth - 1) / 2, alignment: .topLeading)
        Divider()
        DraftVersionAlignedLineView(line: row.current, isPrevious: false)
          .frame(width: (availableWidth - 1) / 2, alignment: .topLeading)
      }
      .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        if row.previous != nil {
          paneHeading("旧版（左侧）")
          DraftVersionAlignedLineView(line: row.previous, isPrevious: true)
        }
        if row.current != nil {
          paneHeading("新版（右侧）")
          DraftVersionAlignedLineView(line: row.current, isPrevious: false)
        }
      }
    }
  }
}

private struct DraftVersionAlignedLineView: View {
  let line: DraftVersionAlignedLine?
  let isPrevious: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: line.map { String($0.lineNumber) } ?? "")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 24, alignment: .trailing)
        .accessibilityHidden(true)
      Text(verbatim: marker)
        .font(.body.monospaced().weight(.semibold))
        .foregroundStyle(changeColor)
        .frame(width: 16)
        .accessibilityHidden(true)
      Text(highlightedText)
        .font(.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(changeColor.opacity(isChanged ? 0.07 : 0))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var isChanged: Bool { line?.kind == .removed || line?.kind == .added }
  private var marker: String {
    switch line?.kind {
    case .removed: "−"
    case .added: "+"
    default: " "
    }
  }
  private var changeColor: Color {
    switch line?.kind {
    case .removed: WorkbenchTheme.risk
    case .added: WorkbenchTheme.success
    default: .secondary
    }
  }

  private var highlightedText: AttributedString {
    guard let line else { return AttributedString(" ") }
    var result = AttributedString()
    for segment in line.segments {
      var piece = AttributedString(segment.text)
      if segment.isChanged {
        piece.backgroundColor = changeColor.opacity(0.2)
        piece.foregroundColor = changeColor
        piece.font = .body.weight(.semibold)
        if line.kind == .removed { piece.strikethroughStyle = .single }
      }
      result.append(piece)
    }
    return result.characters.isEmpty ? AttributedString(" ") : result
  }

  private var accessibilityLabel: String {
    guard let line else { return String(localized: "此版本无对应段落") }
    switch line.kind {
    case .removed: return String(localized: "删除行 \(line.lineNumber)：\(line.text)")
    case .added: return String(localized: "新增行 \(line.lineNumber)：\(line.text)")
    default:
      return isPrevious
        ? String(localized: "旧版第 \(line.lineNumber) 行：\(line.text)")
        : String(localized: "新版第 \(line.lineNumber) 行：\(line.text)")
    }
  }
}
