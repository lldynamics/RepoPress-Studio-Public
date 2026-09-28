import SwiftUI

struct ContentHealthSkeletonLoadingView: View {
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            skeletonBar(width: 140, height: 22)
            skeletonBar(width: 260, height: 14)
          }
          Spacer()
          skeletonBar(width: 110, height: 16)
        }

        HStack(alignment: .top, spacing: 10) {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text("正在生成内容健康快照")
              .font(.caption.weight(.semibold))
            Text("正在检查 Front Matter、链接、SEO 与内容风险。当前分析未提供可显示的分阶段进度。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Button("取消", action: cancel)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("content-health-loading-cancel")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
        ForEach(0..<4) { _ in
          VStack(alignment: .leading, spacing: 8) {
            skeletonBar(width: 60, height: 12)
            skeletonBar(width: 40, height: 20)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(0..<3) { _ in
          HStack(spacing: 12) {
            Circle()
              .fill(Color.primary.opacity(0.08))
              .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 4) {
              skeletonBar(width: 220, height: 14)
              skeletonBar(width: 140, height: 10)
            }
            Spacer()
            skeletonBar(width: 50, height: 14)
          }
          .padding(12)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
        }
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("正在生成内容健康快照，进度未知")
  }

  private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(Color.primary.opacity(0.08))
      .frame(width: width, height: height)
  }

}
