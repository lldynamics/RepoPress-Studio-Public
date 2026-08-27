import SwiftUI

struct RemoteRepositoryCreationConfirmationView: View {
  let providerName: String
  let owner: String
  let repositoryName: String
  @Binding var createsPrivateRepository: Bool
  let isCreating: Bool
  let failureMessage: String?
  let cancelAction: () -> Void
  let createAction: () -> Void

  private var hasCompleteTarget: Bool {
    !owner.trimmedForPublishing.isEmpty && !repositoryName.trimmedForPublishing.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "shippingbox.and.arrow.backward")
          .font(.title2)
          .foregroundStyle(WorkbenchTheme.primary)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text("确认创建仓库")
            .font(.title3.weight(.semibold))
          Text("创建前请核对平台、Owner、仓库名和可见性。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)

      Divider()

      Form {
        Section {
          LabeledContent("仓库平台") {
            Text(verbatim: providerName)
          }
          LabeledContent("仓库 Owner 或 Namespace") {
            Text(verbatim: owner.nilIfEmpty ?? "—")
              .font(.body.monospaced())
              .textSelection(.enabled)
          }
          LabeledContent {
            Text(verbatim: repositoryName.nilIfEmpty ?? "—")
              .font(.body.monospaced())
              .textSelection(.enabled)
          } label: {
            Text("仓库名称")
          }
        }

        Section {
          Picker("可见性", selection: $createsPrivateRepository) {
            Text("私有（推荐）").tag(true)
            Text("公开").tag(false)
          }
          .pickerStyle(.segmented)
          .tint(WorkbenchTheme.navigationSelection)

          if !createsPrivateRepository {
            Label {
              Text("公开仓库中的代码和内容可被任何人查看。")
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
          }
        }

        if !hasCompleteTarget {
          Section {
            Label {
              Text("请先填写 Owner/Namespace 和仓库名称。")
            } icon: {
              Image(systemName: "exclamationmark.circle")
            }
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
          }
        }

        if let failureMessage = failureMessage?.nilIfEmpty {
          Section {
            AccessibleStatusMessage(message: failureMessage, severity: .error)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack(spacing: 10) {
        Button(action: cancelAction) {
          Text("取消")
        }
          .keyboardShortcut(.cancelAction)
          .disabled(isCreating)

        Spacer()

        Button(action: createAction) {
          HStack(spacing: 7) {
            if isCreating {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "plus.circle")
            }
            if createsPrivateRepository {
              Text("创建私有仓库")
            } else {
              Text("创建公开仓库")
            }
          }
        }
        .workbenchProminentActionStyle(
          tint: createsPrivateRepository
            ? WorkbenchTheme.primaryActionFill
            : WorkbenchTheme.warningActionFill
        )
        .keyboardShortcut(.defaultAction)
        .disabled(isCreating || !hasCompleteTarget)
      }
      .padding(20)
    }
    .frame(width: 500)
    .frame(minHeight: 390)
    .interactiveDismissDisabled(isCreating)
  }
}
