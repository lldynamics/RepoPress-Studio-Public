import PublishingWorkbenchCore
import SwiftUI

struct GitConflictItem: Identifiable, Hashable {
  var id: String { filePath }
  let filePath: String
  let localContent: String
  let remoteContent: String
}

struct GitConflictResolverSheet: View {
  @Environment(\.dismiss) private var dismiss
  let conflicts: [GitConflictItem]
  let onResolveConflict: (GitConflictItem, _ keepLocal: Bool) -> Void
  @State private var selectedConflictPath: String?

  private var activeConflict: GitConflictItem? {
    if let selectedConflictPath {
      return conflicts.first { $0.filePath == selectedConflictPath }
    }
    return conflicts.first
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      if conflicts.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 32))
            .foregroundStyle(WorkbenchTheme.success)
          Text("无 Git 冲突")
            .font(.headline)
          Text("远端与本地修改已同步")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          conflictList
            .frame(width: 220)

          Divider()

          if let conflict = activeConflict {
            conflictDiffView(conflict)
          } else {
            VStack(spacing: 8) {
              Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
              Text("请选择冲突文件")
                .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }

      Divider()

      footer
    }
    .frame(minWidth: 800, idealWidth: 920, minHeight: 540, idealHeight: 620)
  }

  private var header: some View {
    HStack {
      Label("Git 冲突可视化消解器", systemImage: "arrow.triangle.merge")
        .font(.headline)
      Spacer()
      Text("检测到 \(conflicts.count) 个并发冲突文件")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
  }

  private var conflictList: some View {
    List(conflicts, selection: $selectedConflictPath) { conflict in
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.warning)
          .font(.caption)
        Text(conflict.filePath)
          .font(.caption.monospaced())
          .lineLimit(1)
      }
      .tag(conflict.filePath)
    }
    .listStyle(.sidebar)
  }

  private func conflictDiffView(_ conflict: GitConflictItem) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Label("本地修改 (Mine / HEAD)", systemImage: "desktopcomputer")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.accentColor.opacity(0.08))

        Divider()

        VStack(alignment: .leading, spacing: 4) {
          Label("远端分支 (Remote / Upstream)", systemImage: "icloud.and.arrow.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.info)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WorkbenchTheme.info.opacity(0.08))
      }

      Divider()

      HStack(spacing: 0) {
        ScrollView {
          Text(conflict.localContent)
            .font(.caption.monospaced())
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)

        Divider()

        ScrollView {
          Text(conflict.remoteContent)
            .font(.caption.monospaced())
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
      }

      Divider()

      HStack(spacing: 12) {
        Button {
          onResolveConflict(conflict, true)
        } label: {
          Label("保留本地修改 (Keep Mine)", systemImage: "checkmark.circle")
        }
        .workbenchProminentActionStyle()

        Button {
          onResolveConflict(conflict, false)
        } label: {
          Label("采纳远端修改 (Accept Remote)", systemImage: "arrow.down.doc")
        }
        .buttonStyle(.bordered)

        Spacer()
      }
      .padding(12)
      .background(.bar)
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("关闭") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
    }
    .padding(12)
  }
}
