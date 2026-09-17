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

    /// 加载（按需下载）指定 Whisper 模型，返回可用实例。带 30 秒超时，避免 HuggingFace 不可达时无限挂起。
    private func instance(for model: String) async throws -> WhisperKit {
        if let inst = instances[model] { return inst }
        if let task = loadingTasks[model] { return try await task.value }

        // 尝试走 HuggingFace 国内镜像，提高模型下载成功率（WhisperKit 若读取 HF_ENDPOINT 即生效，不影响其他逻辑）
        setenv("HF_ENDPOINT", "https://hf-mirror.com", 1)

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
            let inst = try await withTimeout(seconds: 30) { try await task.value }
            instances[model] = inst
            loadingTasks[model] = nil
            return inst
        } catch {
            loadingTasks[model] = nil
            if error.localizedDescription.contains("cancelled") || error.localizedDescription.contains("timed out") {
                throw NSError(domain: "WhisperKit", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "本地语音模型下载超时。首次使用需联网从 HuggingFace 下载模型，当前网络可能无法访问。"])
            }
            throw error
        }
    }

    /// 通用超时包装
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "Timeout", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "操作超时 \(Int(seconds))s"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 转写音频文件（m4a / wav / mp3 / flac 等），返回识别文本。
    /// - Parameters:
    ///   - audioURL: 本地音频文件 URL。
    ///   - model: Whisper 模型名，默认 `openai_whisper-small`（中文多语言、离线、识别准）。
    ///     必须以 `openai_whisper-` 前缀命名，WhisperKit 才能正确解析 HuggingFace 仓库；裸名（如 `base`）会加载失败。
    func transcribe(audioURL: URL, model: String = "openai_whisper-small") async throws -> String {
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
