import SwiftUI

struct ProPurchaseRestoreSection: View {
  let isBusy: Bool
  let isUnlocked: Bool
  let onPurchase: () async -> Void
  let onRestore: () async -> Void
  let message: String?

  var body: some View {
    Section("购买与恢复") {
      HStack {
        Button {
          Task {
            await onPurchase()
          }
        } label: {
          Label("解锁 Pro", systemImage: "crown")
        }
        .disabled(isBusy || isUnlocked)

        Button {
          Task {
            await onRestore()
          }
        } label: {
          Label("恢复购买", systemImage: "arrow.clockwise")
        }
        .disabled(isBusy)
      }

      if isBusy {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在连接 App Store...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let message = message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
