import Foundation
import WhisperKit

/// 本地 WhisperKit 语音识别封装。
/// 完全离线运行：首次使用时按需从 HuggingFace 下载指定 Whisper 模型到沙盒 Application Support 目录，
/// 之后直接调用 Apple Neural Engine / CPU 本地推理。IPA 体积不因此增大。
final class WhisperTranscriber: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var statusText: String = ""

    static let shared = WhisperTranscriber()

    /// 已加载的 WhisperKit 实例（按模型名缓存）。
    private var instances: [String: WhisperKit] = [:]
    private var loadingTasks: [String: Task<WhisperKit, Error>] = [:]

    private init() {}

    /// 加载（按需下载）指定 Whisper 模型，返回可用实例。
    private func instance(for model: String) async throws -> WhisperKit {
        if let inst = instances[model] { return inst }
        if let task = loadingTasks[model] { return try await task.value }

        let task = Task<WhisperKit, Error> { [weak self] in
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WhisperKit", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var config = WhisperKitConfig()
            config.model = model
            config.downloadBase = base
            config.verbose = false
            return try await WhisperKit(config)
        }
        loadingTasks[model] = task
        do {
            let inst = try await task.value
            instances[model] = inst
            loadingTasks[model] = nil
            return inst
        } catch {
            loadingTasks[model] = nil
            throw error
        }
    }

    /// 转写音频文件（m4a / wav / mp3 / flac 等），返回识别文本。
    /// - Parameters:
    ///   - audioURL: 本地音频文件 URL。
    ///   - model: Whisper 模型名，默认 `base`（中文场景准确度与体积的平衡点；追求更高准确度可传 `small`）。
    func transcribe(audioURL: URL, model: String = "base") async throws -> String {
        await MainActor.run { self.isBusy = true; self.statusText = "正在准备本地语音模型…" }
        let wk: WhisperKit
        do {
            wk = try await instance(for: model)
        } catch {
            await MainActor.run { self.isBusy = false; self.statusText = "" }
            throw error
        }
        await MainActor.run { self.statusText = "正在识别语音…" }
        let decodeOptions = DecodingOptions(language: "zh")
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { self.isBusy = false; self.statusText = "" }
        return text
    }
}
