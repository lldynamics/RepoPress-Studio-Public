import AppKit
import SwiftUI

/// One truncated path in the metadata row; the menu retains the former
/// breadcrumb's copy, parent-path and Finder operations at every width.
struct InteractiveBreadcrumbView: View {
  let markdownPath: String
  let fileURL: URL?

  var body: some View {
    Menu {
      breadcrumbActions
      if !parentPaths.isEmpty {
        Divider()
        ForEach(parentPaths, id: \.self) { path in
          Button {
            copyToClipboard(path)
          } label: {
            Text(verbatim: path)
          }
        }
      }
    } label: {
      Text(verbatim: markdownPath)
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(.workbenchSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("显示完整路径和操作")
        .accessibilityValue(markdownPath)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: false, vertical: true)
    .contextMenu { breadcrumbActions }
    .help(markdownPath)
    .accessibilityLabel("显示完整路径和操作")
    .accessibilityValue(markdownPath)
    .accessibilityIdentifier("markdown-article-path-menu")
  }

  var parentPaths: [String] {
    Self.parentPaths(for: markdownPath)
  }

  static func parentPaths(for path: String) -> [String] {
    let segments = path.split(separator: "/")
    return segments.indices.dropLast().map { index in
      segments.prefix(index + 1).joined(separator: "/")
    }
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

    Button {
      copyToClipboard((markdownPath as NSString).lastPathComponent)
    } label: {
      Label("复制文件名", systemImage: "text.quote")
    }

    Divider()

    Button {
      guard let fileURL else { return }
      NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    } label: {
      Label("在 Finder 中显示", systemImage: "folder")
    }
    .disabled(fileURL == nil)
  }

  private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
