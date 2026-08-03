import AppKit
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers

struct LocalWhisperSection: View {
  let selectedDraftTitle: String?
  let appendTranscript: (String) -> Bool

  @AppStorage("localWhisperExecutablePath") private var executablePath = ""
  @AppStorage("localWhisperModelPath") private var modelPath = ""
  @AppStorage("localWhisperLanguage") private var language = "auto"
  @State private var isTranscribing = false
  @State private var statusMessage: String?
  @State private var transcriptionTask: Task<Void, Never>?

  var body: some View {
    Section {
      HStack {
        TextField("whisper-cli / whisper.cpp 路径", text: $executablePath)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("本地 Whisper 可执行文件路径")
        Button("选择…") {
          if let url = chooseFile(
            message: "选择本地 whisper-cli / whisper.cpp 可执行文件",
            contentTypes: [.unixExecutable, .data]
          ) {
            executablePath = url.path
          }
        }
      }

      HStack {
        TextField("本地 Whisper 模型路径", text: $modelPath)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("本地 Whisper 模型路径")
        Button("选择…") {
          if let url = chooseFile(
            message: "选择本地 Whisper 模型文件",
            contentTypes: [.data]
          ) {
            modelPath = url.path
          }
        }
      }

      TextField("语言（auto / zh / en）", text: $language)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("本地 Whisper 转写语言")

      HStack {
        Button {
          transcribeAudio()
        } label: {
          Label("选择音频并插入转写", systemImage: "waveform.and.mic")
        }
        .workbenchProminentActionStyle()
        .disabled(isTranscribing || selectedDraftTitle == nil || !isConfigured)

        if isTranscribing {
          ProgressView()
            .controlSize(.small)
          Button("停止", role: .cancel) {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            isTranscribing = false
            statusMessage = "已停止本地转写。"
          }
          .buttonStyle(.borderless)
        }
      }

      if let selectedDraftTitle {
        Text("目标文章：\(selectedDraftTitle)")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("请先在写作区选择文章。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    } header: {
      Text("本地 Whisper 转写")
    } footer: {
      Text("使用本机 whisper.cpp-compatible CLI 和本地模型，不上传音频。当前支持从音频生成纯文本并追加到所选文章。")
    }
    .onAppear {
      if executablePath.trimmedForPublishing.isEmpty {
        executablePath = LocalWhisperConfiguration.discoveredExecutablePath ?? ""
      }
    }
    .onDisappear {
      transcriptionTask?.cancel()
      transcriptionTask = nil
    }
  }

  private var isConfigured: Bool {
    LocalWhisperConfiguration(
      executablePath: executablePath,
      modelPath: modelPath,
      language: language
    ).isConfigured
  }

  private func transcribeAudio() {
    guard let audioURL = chooseFile(
      message: "选择要在本机转写的音频",
      contentTypes: [.audio, .data]
    ) else { return }
    let configuration = LocalWhisperConfiguration(
      executablePath: executablePath,
      modelPath: modelPath,
      language: language
    )
    isTranscribing = true
    statusMessage = "正在本机运行 Whisper…"
    transcriptionTask?.cancel()
    transcriptionTask = Task { @MainActor in
      defer {
        isTranscribing = false
        transcriptionTask = nil
      }
      do {
        let result = try await LocalWhisperTranscriptionService().transcribe(
          audioURL: audioURL,
          configuration: configuration
        )
        guard !Task.isCancelled else { return }
        if appendTranscript(result.text) {
          statusMessage = "已使用 \(result.executableName) 插入本地转写。"
        }
      } catch is CancellationError {
        statusMessage = "已停止本地转写。"
      } catch {
        statusMessage = error.localizedDescription
      }
    }
  }

  private func chooseFile(
    message: String,
    contentTypes: [UTType]
  ) -> URL? {
    let panel = NSOpenPanel()
    panel.message = message
    panel.prompt = "选择"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = contentTypes
    return panel.runModal() == .OK ? panel.url : nil
  }
}
