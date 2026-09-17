import Foundation
import WhisperKit

/// 本地 WhisperKit 语音识别封装。
/// 完全离线运行：首次使用时显式从 HuggingFace 国内镜像(hf-mirror.com)下载指定 Whisper 模型到沙盒 Application Support 目录，
/// 之后直接调用 Apple Neural Engine / CPU 本地推理。IPA 体积不因此增大。
final class WhisperTranscriber: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var statusText: String = ""
    /// 首次下载语音模型时的进度（0...1），供 UI 展示百分比，避免用户无法区分“下载中 / 卡死”
    @Published var downloadProgress: Double = 0
    @Published var isDownloadingModel: Bool = false

    static let shared = WhisperTranscriber()

    /// 已加载的 WhisperKit 实例（按模型名缓存）
    private var instances: [String: WhisperKit] = [:]
    private var loadingTasks: [String: Task<WhisperKit, Error>] = [:]

    /// 国内镜像端点（显式传给 WhisperKit 的 endpoint 参数，规避 HF_ENDPOINT 环境变量在 1.1.0 不一定生效的问题）
    private let mirrorEndpoint = "https://hf-mirror.com"

    private init() {}

    /// 加载（按需下载）指定 Whisper 模型，返回可用实例。带 600 秒超时，避免镜像不可达时无限挂起；small 模型约 480–500MB，弱网下需数分钟。
    private func instance(for model: String) async throws -> WhisperKit {
        if let inst = instances[model] { return inst }
        if let task = loadingTasks[model] { return try await task.value }

        let task = Task<WhisperKit, Error> { [weak self] in
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WhisperKit", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            // 显式下载以展示进度（缓存命中时秒回，不会重复下载）。同时强制走国内镜像。
            // 注意：WhisperKit(config) 初始化内部调用 download 时不透传进度回调，故必须在此显式下载拿进度。
            await MainActor.run {
                self?.isDownloadingModel = true
                self?.downloadProgress = 0
                self?.statusText = "正在下载语音模型 0%"
            }
            _ = try await WhisperKit.download(
                variant: model,
                downloadBase: base,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                endpoint: self?.mirrorEndpoint ?? "https://hf-mirror.com"
            ) { prog in
                // 兼容 WhisperKit 进度回调的两种可能签名（Progress 或 Double）
                let fraction: Double
                if let p = prog as? Progress { fraction = p.fractionCompleted }
                else if let d = prog as? Double { fraction = d }
                else { fraction = 0 }
                let pct = Int(fraction * 100)
                Task { @MainActor in
                    self?.downloadProgress = fraction
                    self?.statusText = "正在下载语音模型 \(pct)%"
                }
            }
            await MainActor.run {
                self?.isDownloadingModel = false
                self?.statusText = "正在加载语音模型…"
            }

            // 沿用原先可工作的加载路径（downloadBase + model），仅额外显式指定镜像端点，确保 tokenizer 等也从镜像拉取
            let config = WhisperKitConfig(
                model: model,
                downloadBase: base,
                verbose: false,
                load: true,
                download: true,
                modelEndpoint: self?.mirrorEndpoint ?? "https://hf-mirror.com"
            )
            return try await WhisperKit(config)
        }
        loadingTasks[model] = task
        do {
            let inst = try await withTimeout(seconds: 600) { try await task.value }
            instances[model] = inst
            loadingTasks[model] = nil
            return inst
        } catch {
            loadingTasks[model] = nil
            await MainActor.run { self.isDownloadingModel = false; self.downloadProgress = 0 }
            if error.localizedDescription.contains("cancelled") || error.localizedDescription.contains("timed out") {
                throw NSError(domain: "WhisperKit", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "本地语音模型下载超时。首次使用需联网从 HuggingFace 镜像(hf-mirror.com)下载模型，当前网络可能无法访问。"])
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
        await MainActor.run { self.isBusy = true }
        let wk: WhisperKit
        do {
            wk = try await instance(for: model)
        } catch {
            await MainActor.run { self.isBusy = false; self.isDownloadingModel = false; self.statusText = "" }
            throw error
        }
        await MainActor.run { self.statusText = "正在识别语音…" }
        let decodeOptions = DecodingOptions(language: "zh")
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run { self.isBusy = false; self.isDownloadingModel = false; self.statusText = "" }
        return text
    }
}
