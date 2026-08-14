import PublishingWorkbenchCore
import SwiftUI

extension KnowledgeSourceListColumn {
  var batchActionBar: some View {
    HStack(spacing: 6) {
      Text("已选 \(selectedDocumentIDs.count) 条")
        .font(.caption.weight(.semibold))
        .monospacedDigit()
      Spacer(minLength: 4)
      Button("完成") {
        exitBatchSelection()
      }
      .buttonStyle(.borderless)
      .help("退出批量选择（Esc）")
      .accessibilityLabel("完成批量选择")

      Menu {
        Button("未分类") {
          knowledge.moveDocuments(selectedDocumentIDs, to: nil)
          retainVisibleBatchSelection()
        }
        if !knowledge.folders.isEmpty { Divider() }
        ForEach(knowledge.folders) { folder in
          Button(folder.name) {
            knowledge.moveDocuments(selectedDocumentIDs, to: folder.id)
            retainVisibleBatchSelection()
          }
        }
      } label: {
        Image(systemName: "folder")
      }
      .help("批量移动")
      .accessibilityLabel("批量移动所选资料")

      Button {
        batchTags = ""
        isBatchTagEditorPresented = true
      } label: {
        Image(systemName: "tag")
      }
      .buttonStyle(.plain)
      .help("批量添加标签")
      .accessibilityLabel("批量添加标签")

      Menu {
        Button("建立本地语义索引") {
          knowledge.setAllowsLocalSemanticIndex(true, documentIDs: selectedDocumentIDs)
        }
        Button("关闭本地语义索引") {
          knowledge.setAllowsLocalSemanticIndex(false, documentIDs: selectedDocumentIDs)
        }
        Divider()
        Button("允许发送给远程 AI") {
          knowledge.setAllowsRemoteAIUse(true, documentIDs: selectedDocumentIDs)
        }
        Button("禁止发送给远程 AI") {
          knowledge.setAllowsRemoteAIUse(false, documentIDs: selectedDocumentIDs)
        }
      } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .help("批量设置资料权限")
      .accessibilityLabel("批量设置资料权限")

      Menu {
        Button {
          exportBatchSelection()
        } label: {
          Label("导出为 Markdown…", systemImage: "square.and.arrow.up")
        }
        Button {
          let ids = selectedDocumentIDs
          Task { await knowledge.rebuildSemanticIndex(for: ids) }
        } label: {
          Label("重建语义索引", systemImage: "arrow.triangle.2.circlepath")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .help("更多批量操作")
      .accessibilityLabel("更多批量操作")

      Button(role: .destructive) {
        isBatchRecycleConfirmationPresented = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .help("移到回收站")
      .accessibilityLabel("将所选资料移到回收站")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.06))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("批量操作，已选择 \(selectedDocumentIDs.count) 条资料")
  }

  var parsedBatchTags: [String] {
    batchTags
      .components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  func confirmBatchTags() {
    knowledge.addTags(parsedBatchTags, to: selectedDocumentIDs)
    batchTags = ""
  }

  func confirmBatchRecycle() {
    let count = selectedDocumentIDs.count
    guard knowledge.moveToRecycleBin(selectedDocumentIDs) else { return }
    selectedDocumentIDs = []
    EditorAccessibilityAnnouncementCenter.announce(
      "已将 \(count) 条资料移到回收站。",
      priority: .medium
    )
  }

  func exitBatchSelection() {
    guard selectedDocumentIDs.count > 1 else { return }
    if let selectedDocumentID = knowledge.selectedDocumentID {
      selectedDocumentIDs = [selectedDocumentID]
    } else {
      selectedDocumentIDs = []
    }
    EditorAccessibilityAnnouncementCenter.announce(
      "已退出批量选择。",
      priority: .low
    )
  }

  private func exportBatchSelection() {
    guard let destinationURL = KnowledgeBatchExportSelectionPanel.chooseDestinationDirectory() else {
      return
    }
    let ids = selectedDocumentIDs
    Task {
      _ = await knowledge.exportDocuments(ids, to: destinationURL)
    }
  }

  func handleListSelectionChange(previous: Set<UUID>, current: Set<UUID>) {
    guard !current.isEmpty else {
      knowledge.selectDocument(nil)
      return
    }
    if let selectedID = knowledge.selectedDocumentID, current.contains(selectedID) {
      return
    }
    let newlySelected = current.subtracting(previous).first ?? current.first
    knowledge.selectDocument(newlySelected)
  }

  func synchronizeListSelection() {
    guard searchText.trimmedForPublishing.isEmpty else { return }
    guard let selectedID = knowledge.selectedDocumentID,
          listPresentation.documentRows.contains(where: { $0.id == selectedID }) else {
      selectedDocumentIDs = []
      return
    }
    if selectedDocumentIDs.count <= 1 || !selectedDocumentIDs.contains(selectedID) {
      selectedDocumentIDs = [selectedID]
    }
  }

  func retainVisibleBatchSelection() {
    let visibleIDs = Set(listPresentation.documentRows.map(\.id))
    selectedDocumentIDs.formIntersection(visibleIDs)
    synchronizeListSelection()
  }
}
