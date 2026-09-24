import AppKit
import SwiftUI

struct InteractiveBreadcrumbView: View {
  let markdownPath: String
  let fileURL: URL?
  let pathSegments: [String]

  @State private var hoveredSegmentIndex: Int? = nil

  private var shouldCollapse: Bool {
    pathSegments.count > 4 || markdownPath.count > 56
  }

  init(markdownPath: String, fileURL: URL?) {
    self.markdownPath = markdownPath
    self.fileURL = fileURL
    let cleaned = markdownPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    self.pathSegments = cleaned.isEmpty ? [markdownPath] : cleaned.components(separatedBy: "/")
  }

  var body: some View {
    Group {
      if shouldCollapse { collapsedBreadcrumb } else { fullBreadcrumb }
    }
    .lineLimit(1)
    .contextMenu {
      breadcrumbActions
    }
    .help(markdownPath)
  }

  private var fullBreadcrumb: some View {
    HStack(spacing: 3) {
      ForEach(Array(pathSegments.enumerated()), id: \.offset) { index, segment in
        let isLast = index == pathSegments.count - 1
        HStack(spacing: 3) {
          breadcrumbButton(segment: segment, index: index, isLast: isLast)
          if !isLast {
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  private var collapsedBreadcrumb: some View {
    HStack(spacing: 4) {
      Button {
        copyToClipboard(pathSegments.first.map { String($0) } ?? markdownPath)
      } label: {
        Text(pathSegments.first ?? markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("复制路径起点")
      Menu {
        breadcrumbActions
        Divider()
        ForEach(Array(pathSegments.enumerated()), id: \.offset) { index, segment in
          Button {
            copyToClipboard(pathSegments.prefix(index + 1).joined(separator: "/"))
          } label: {
            Text(segment).lineLimit(1)
          }
        }
      } label: {
        Label("完整路径", systemImage: "ellipsis")
          .labelStyle(.iconOnly)
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("显示完整路径和操作")
      Button {
        revealInFinder()
      } label: {
        Text(pathSegments.last ?? markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .buttonStyle(.plain)
      .accessibilityHint("在 Finder 中显示")
    }
  }

  private func breadcrumbButton(segment: String, index: Int, isLast: Bool) -> some View {
    Button {
      if isLast {
        revealInFinder()
      } else {
        copyToClipboard(pathSegments.prefix(index + 1).joined(separator: "/"))
      }
    } label: {
      Text(segment)
        .font(.caption.monospaced())
        .foregroundStyle(isLast ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(hoveredSegmentIndex == index ? Color.primary.opacity(0.08) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .accessibilityHint(isLast ? "在 Finder 中显示" : "复制相对路径")
    .onHover { hoveredSegmentIndex = $0 ? index : nil }
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
