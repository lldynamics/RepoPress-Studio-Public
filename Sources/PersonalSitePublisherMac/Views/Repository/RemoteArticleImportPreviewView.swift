import PublishingWorkbenchCore
import SwiftUI

struct RemoteArticleImportPreviewView: View {
  let files: [RepositoryChangedFile]
  let cancelAction: () -> Void
  let confirmAction: ([String]) -> Void

  @State private var selectedPaths: Set<String>

  init(
    files: [RepositoryChangedFile],
    cancelAction: @escaping () -> Void,
    confirmAction: @escaping ([String]) -> Void
  ) {
    self.files = files
    self.cancelAction = cancelAction
    self.confirmAction = confirmAction
    _selectedPaths = State(initialValue: Set(files.map(\.displayPath)))
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Label("预览远端文章导入", systemImage: "tray.and.arrow.down")
          .font(.title3.weight(.semibold))
        Text("选择要导入的文章。相同仓库路径的现有草稿会先保存版本快照，再使用远端内容更新。")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)

      Divider()

      List(files) { file in
        VStack(alignment: .leading, spacing: 8) {
          Toggle(isOn: selectionBinding(for: file.displayPath)) {
            HStack(spacing: 8) {
              Image(systemName: file.kind == .added ? "plus.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(file.kind == .added ? WorkbenchTheme.success : WorkbenchTheme.warning)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                WorkbenchPathIdentity(path: file.displayPath)
                Text("\(file.kind.localizedDisplayName) · \(file.status)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }

          if let lineDiff = file.lineDiff?.nilIfEmpty {
            Text(lineDiff)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(8)
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                WorkbenchBackgroundStyle.control,
                in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              )
          }
        }
        .padding(.vertical, 6)
      }
      .listStyle(.inset)

      Divider()

      HStack {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text("已选择 \(selectedPaths.count) / \(files.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          confirmAction(files.map(\.displayPath).filter(selectedPaths.contains))
        } label: {
          Label("确认导入", systemImage: "tray.and.arrow.down.fill")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(selectedPaths.isEmpty)
      }
      .padding(16)
    }
    .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
  }

  private func selectionBinding(for path: String) -> Binding<Bool> {
    Binding(
      get: { selectedPaths.contains(path) },
      set: { isSelected in
        if isSelected {
          selectedPaths.insert(path)
        } else {
          selectedPaths.remove(path)
        }
      }
    )
  }
}
