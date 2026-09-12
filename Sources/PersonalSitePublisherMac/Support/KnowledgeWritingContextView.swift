import PublishingWorkbenchCore
import SwiftUI

/// A small, shared destination context for surfaces that collect material for
/// an article. The destination is deliberately the store's current selection:
/// changing it uses the same focus routing as the writing list and therefore
/// keeps the window-scoped article identity in sync.
struct KnowledgeWritingContextView: View {
  let store: WorkbenchStore
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  @Environment(\.workspaceWindowSession) private var workspaceWindowSession
  @Environment(\.workspaceWindowIsKey) private var workspaceWindowIsKey

  init(store: WorkbenchStore) {
    self.store = store
    _publishing = ObservedObject(wrappedValue: store.publishing)
  }

  private var targetDraftID: UUID? {
    if let workspaceWindowSession {
      return workspaceWindowSession.selectedDraftID
    }
    return workspaceWindowIsKey ? publishing.selectedDraftID : nil
  }

  private var currentDraft: ArticleDraft? {
    guard let targetDraftID else { return nil }
    return publishing.drafts.first { $0.id == targetDraftID }
  }

  private var targetDrafts: [ArticleDraft] {
    publishing.drafts.sorted { lhs, rhs in
      if lhs.id != rhs.id {
        let lhsIsSelected = lhs.id == targetDraftID
        let rhsIsSelected = rhs.id == targetDraftID
        if lhsIsSelected != rhsIsSelected { return lhsIsSelected }
      }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("资料写作目标", systemImage: "text.book.closed")
          .font(.workbenchCardTitle)
        Spacer(minLength: 4)
        targetPicker
      }

      if let draft = currentDraft {
        Text("正在为《\(safeTitle(for: draft))》收集资料")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("正在为《\(safeTitle(for: draft))》收集资料")
      } else {
        Text("尚未选择文章，请先选择一个写作目标。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button {
        returnToWriting()
      } label: {
        Label("返回写作", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.link)
      .help("返回当前文章的写作界面")
      .accessibilityIdentifier("knowledge-return-to-writing")
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-writing-context")
  }

  @ViewBuilder
  private var targetPicker: some View {
    Menu {
      if targetDrafts.isEmpty {
        Text("暂无可用文章")
      } else {
        ForEach(targetDrafts) { draft in
          Button {
            selectTarget(draft)
          } label: {
            Label {
              Text(menuTitle(for: draft))
            } icon: {
              Image(systemName: draft.id == targetDraftID ? "checkmark" : "doc.text")
            }
          }
          .disabled(draft.id == targetDraftID)
          .help(safeTitle(for: draft))
        }
      }
    } label: {
      Label("更换目标", systemImage: "arrow.left.arrow.right")
    }
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .help("更换资料要写入的文章")
    .accessibilityLabel("更换资料写作目标")
    .accessibilityIdentifier("knowledge-writing-target-picker")
  }

  private func safeTitle(for draft: ArticleDraft) -> String {
    let display = store.privateContentDisplay(for: draft)
    return display.isMasked
      ? String(localized: "私密文章")
      : (display.title.nilIfEmpty ?? String(localized: "未命名文章"))
  }

  private func menuTitle(for draft: ArticleDraft) -> String {
    String(safeTitle(for: draft).prefix(60))
  }

  private func selectTarget(_ draft: ArticleDraft) {
    if let workspaceWindowSession {
      workspaceWindowSession.selectContext(
        section: workspaceWindowSession.selectedSection,
        draftID: draft.id
      ) { section, draftID in
        guard workspaceWindowIsKey else { return }
        if let draftID {
          _ = store.focusDraft(draftID, section: section)
        } else {
          store.selectSection(section)
        }
      }
    } else {
      _ = store.focusDraft(draft.id, section: publishing.selectedSection)
    }
    EditorAccessibilityAnnouncementCenter.announce(
      String(localized: "已将资料写作目标切换为《\(safeTitle(for: draft))》。"),
      priority: .medium
    )
  }

  private func returnToWriting() {
    if let workspaceWindowSession {
      workspaceWindowSession.selectContext(
        section: .writing,
        draftID: targetDraftID
      ) { section, draftID in
        guard workspaceWindowIsKey else { return }
        if let draftID {
          _ = store.focusDraft(draftID, section: section)
        } else {
          store.selectSection(section)
        }
      }
    } else {
      if let targetDraftID {
        _ = store.focusDraft(targetDraftID, section: .writing)
      } else {
        store.selectSection(.writing)
      }
    }
  }
}
