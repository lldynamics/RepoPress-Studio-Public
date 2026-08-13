import AppKit
import SwiftUI

struct InteractiveBreadcrumbView: View {
  let markdownPath: String
  let fileURL: URL?

  @State private var hoveredSegmentIndex: Int? = nil

  var pathSegments: [String] {
    let cleaned = markdownPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !cleaned.isEmpty else { return [markdownPath] }
    return cleaned.components(separatedBy: "/")
  }

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(pathSegments.enumerated()), id: \.offset) { index, segment in
        let isLast = index == pathSegments.count - 1

        HStack(spacing: 3) {
          Text(segment)
            .font(.caption.monospaced())
            .foregroundStyle(isLast ? .primary : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(
                  hoveredSegmentIndex == index
                    ? Color.primary.opacity(0.08)
                    : Color.clear
                )
            )
            .onHover { isHovered in
              hoveredSegmentIndex = isHovered ? index : nil
            }

          if !isLast {
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .lineLimit(1)
    .contextMenu {
      breadcrumbActions
    }
    .help(markdownPath)
  }

  @ViewBuilder
  private var breadcrumbActions: some View {
    Button {
      copyToClipboard(markdownPath)
    } label: {
      Label("复制相对路径", systemImage: "doc.on.doc")
    }

    if let fullPath = fileURL?.path {
      Button {
        copyToClipboard(fullPath)
      } label: {
        Label("复制绝对路径", systemImage: "doc.on.doc.fill")
      }
    }

    if let fileName = pathSegments.last {
      Button {
        copyToClipboard(fileName)
      } label: {
        Label("复制文件名", systemImage: "text.quote")
      }
    }

    Divider()

    Button {
      revealInFinder()
    } label: {
      Label("在 Finder 中显示", systemImage: "folder")
    }
  }

  private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func revealInFinder() {
    if let url = fileURL {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: markdownPath)
    }
  }
}
