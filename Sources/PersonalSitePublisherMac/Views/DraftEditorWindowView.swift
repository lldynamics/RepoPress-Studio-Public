import PublishingWorkbenchCore
import SwiftUI

struct DraftEditorWindowView: View {
  @ObservedObject var store: WorkbenchStore
  let draftID: UUID?
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("defaultShowsInspector") private var defaultShowsInspector = true
  @State private var isInspectorPresented = true
  @State private var didApplyDefaultInspector = false

  var body: some View {
    ZStack {
      if let draftID, let fallbackDraft = store.drafts.first(where: { $0.id == draftID }) {
        let draft = Binding<ArticleDraft>(
          get: {
            store.drafts.first(where: { $0.id == draftID }) ?? fallbackDraft
          },
          set: { updatedDraft in
            store.updateDraft(updatedDraft)
          }
        )

        HSplitView {
          MacMarkdownComposerView(draft: draft, store: store)
            .frame(minWidth: 620)

          if isInspectorPresented {
            EditorInspectorView(
              draft: draft,
              store: store
            )
              .frame(minWidth: 300, idealWidth: 340, maxWidth: 430)
          }
        }
        .navigationTitle(draft.wrappedValue.title)
        .onAppear {
          if !didApplyDefaultInspector {
            isInspectorPresented = defaultShowsInspector
            didApplyDefaultInspector = true
          }
        }
        .toolbar {
          ToolbarItemGroup {
            Button {
              store.save()
            } label: {
              Label("保存", systemImage: "tray.and.arrow.down")
            }
            .disabled(!store.canUseProtectedWorkbench)

            Button {
              _ = store.focusDraft(draftID, section: .writing)
            } label: {
              Label("在工作台显示", systemImage: "sidebar.left")
            }
            .disabled(!store.canUseProtectedWorkbench)

            Button {
              _ = store.focusDraft(draftID, section: .contentHealth)
            } label: {
              Label("发布检查", systemImage: "checklist")
            }
            .disabled(!store.canUseProtectedWorkbench)

            Button {
              isInspectorPresented.toggle()
            } label: {
              Label("Inspector", systemImage: "sidebar.right")
            }
            .disabled(!store.canUseProtectedWorkbench)
          }
        }
        .disabled(store.isPrivacyLocked)
        .accessibilityHidden(store.isPrivacyLocked)
      } else {
        EmptyStateView(
          title: "找不到这篇文章",
          message: "这篇文章可能已经被删除，回到主工作台选择其他草稿。",
          systemImage: "doc.badge.exclamationmark"
        )
        .frame(minWidth: 720, minHeight: 520)
      }

      if store.isPrivacyLocked {
        PrivacyLockOverlay(store: store)
      }
    }
    .onChange(of: scenePhase) { _, newValue in
      if newValue != .active {
        store.lockPrivacyIfNeededForInactiveScene()
      }
    }
    .onDisappear {
      _ = store.flushPendingChanges()
    }
  }
}
