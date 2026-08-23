import PublishingWorkbenchCore
import SwiftUI

enum LocalSitePreviewTrustEntryPoint: String, CaseIterable {
  case panel
  case markdownPopover
}

struct LocalSitePreviewTrustConfirmationPresentation: Equatable {
  let title: String
  let repositoryLabel: String
  let repositoryPath: String
  let commandLabel: String
  let command: String
  let riskMessage: String
  let confirmTitle: String
  let cancelTitle: String

  init(request: LocalSitePreviewAuthorizationRequest) {
    title = String(localized: "确认运行本地预览命令")
    repositoryLabel = String(localized: "仓库路径")
    repositoryPath = request.repositoryPath
    commandLabel = String(localized: "将要执行的命令")
    command = request.command
    riskMessage = String(
      localized: "本地预览会在这台 Mac 上执行仓库中的代码。确认后会在这台 Mac 上记住此仓库和命令；仅当你信任它们时继续。命令或项目清单变更后需重新确认。"
    )
    confirmTitle = String(localized: "确认并启动")
    cancelTitle = String(localized: "取消")
  }
}

enum LocalSitePreviewTrustConfirmationPolicy {
  static func request(
    from disposition: LocalSitePreviewStartDisposition,
    entryPoint _: LocalSitePreviewTrustEntryPoint
  ) -> LocalSitePreviewAuthorizationRequest? {
    guard case .needsConfirmation(let request) = disposition else { return nil }
    return request
  }

  static func repositoryStartOpensConfirmationPanel(
    commandActionAvailable: Bool
  ) -> Bool {
    commandActionAvailable
  }
}

struct LocalSitePreviewTrustConfirmationView: View {
  let request: LocalSitePreviewAuthorizationRequest
  let entryPoint: LocalSitePreviewTrustEntryPoint
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  private var presentation: LocalSitePreviewTrustConfirmationPresentation {
    LocalSitePreviewTrustConfirmationPresentation(request: request)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(presentation.title, systemImage: "terminal.fill")
        .font(.title2.weight(.semibold))

      VStack(alignment: .leading, spacing: 7) {
        Text(presentation.repositoryLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(presentation.repositoryPath)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: 7) {
        Text(presentation.commandLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(presentation.command)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
      }

      Label(presentation.riskMessage, systemImage: "exclamationmark.shield.fill")
        .font(.callout)
        .foregroundStyle(WorkbenchTheme.warning)

      HStack {
        Spacer()
        Button(presentation.cancelTitle, role: .cancel, action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Button(presentation.confirmTitle, action: confirmAction)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(width: 580)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("local-site-preview-trust-confirmation-\(entryPoint.rawValue)")
  }
}

private struct LocalSitePreviewTrustConfirmationModifier: ViewModifier {
  @Binding var request: LocalSitePreviewAuthorizationRequest?
  let entryPoint: LocalSitePreviewTrustEntryPoint
  let authorize: (LocalSitePreviewAuthorizationRequest) -> LocalSitePreviewStartDisposition

  func body(content: Content) -> some View {
    content.sheet(item: $request) { pendingRequest in
      LocalSitePreviewTrustConfirmationView(
        request: pendingRequest,
        entryPoint: entryPoint,
        cancelAction: {
          request = nil
        },
        confirmAction: {
          request = nil
          let disposition = authorize(pendingRequest)
          request = LocalSitePreviewTrustConfirmationPolicy.request(
            from: disposition,
            entryPoint: entryPoint
          )
        }
      )
    }
  }
}

extension View {
  func localSitePreviewTrustConfirmation(
    request: Binding<LocalSitePreviewAuthorizationRequest?>,
    entryPoint: LocalSitePreviewTrustEntryPoint,
    authorize: @escaping (LocalSitePreviewAuthorizationRequest)
      -> LocalSitePreviewStartDisposition
  ) -> some View {
    modifier(
      LocalSitePreviewTrustConfirmationModifier(
        request: request,
        entryPoint: entryPoint,
        authorize: authorize
      )
    )
  }
}
