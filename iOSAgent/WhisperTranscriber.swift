import Foundation
import WhisperKit

/// 本地 WhisperKit 语音识别封装。
/// 完全离线运行：首次使用时从 HuggingFace(huggingface.co)下载指定 Whisper 模型到沙盒 Application Support 目录（国内需 VPN），
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

    /// 官方 HuggingFace 端点。argmaxinc/whisperkit-coreml 模型仓库在国内镜像(hf-mirror.com)上仅镜像了 API 元数据、
    /// 未镜像文件下载(返回404)，故必须使用官方端点；国内网络需开启可访问 huggingface.co 的 VPN/境外网络才能首次
    /// 下载(约480MB)，后续复用本地缓存则无需联网。
    private let modelEndpoint = "https://huggingface.co"

    private init() {}

    /// 检查本地模型目录是否完整：3 个 mlmodelc 的 weights/weight.bin 均存在，且 config.json / generation_config.json 存在
    private static func isModelFolderComplete(_ folder: URL) -> Bool {
        let fm = FileManager.default
        for sub in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let weight = folder.appendingPathComponent("\(sub).mlmodelc").appendingPathComponent("weights/weight.bin")
            guard fm.fileExists(atPath: weight.path) else { return false }
        }
        return fm.fileExists(atPath: folder.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("generation_config.json").path)
    }

    /// 加载（按需下载）指定 Whisper 模型，返回可用实例。带 600 秒超时，避免镜像不可达时无限挂起；small 模型约 480–500MB，弱网下需数分钟。
    private func instance(for model: String) async throws -> WhisperKit {
        if let inst = instances[model] { return inst }
        if let task = loadingTasks[model] { return try await task.value }

        let task = Task<WhisperKit, Error> { [weak self] in
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WhisperKit", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            // 显式下载以展示真实进度（缓存有效时秒回；缓存损坏时由下方 force 分支重新完整下载）。
            // 关键：用 download 返回的确切 modelFolder 加载，避免 WhisperKit(config) 内部重新 resolve 到
            // 之前 HF_ENDPOINT / hf-mirror 时代半路下载留下的损坏/不完整缓存（会报 invalid metadata 错误）。
            func downloadAndLoad(force: Bool) async throws -> WhisperKit {
                let modelFolder = base.appendingPathComponent(model, isDirectory: true)
                // 自愈：若本地模型目录缺失关键文件（损坏/不完整缓存），清理后重新下载
                if force || !WhisperTranscriber.isModelFolderComplete(modelFolder) {
                    try? FileManager.default.removeItem(at: modelFolder)
                }
                await MainActor.run {
                    self?.isDownloadingModel = true
                    self?.downloadProgress = 0
                    self?.statusText = "正在下载语音模型 0%"
                }
                let downloaded = try await WhisperKit.download(
                    variant: model,
                    downloadBase: base,
                    useBackgroundSession: false,
                    from: "argmaxinc/whisperkit-coreml",
                    endpoint: self?.modelEndpoint ?? "https://huggingface.co"
                ) { prog in
                    // WhisperKit 1.1.0 进度回调入参即为 Progress 类型
                    let fraction = max(0, min(1, prog.fractionCompleted))
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
                // 用 download 返回的确切路径加载（download:false 不再 resolve 旧缓存），tokenizer 等已随模型一并下载
                // 注意：WhisperKitConfig 成员初始化器要求参数按声明顺序，load 必须排在 download 之前
                let config = WhisperKitConfig(
                    modelFolder: downloaded.path,
                    load: true,
                    download: false
                )
                return try await WhisperKit(config)
            }

            do {
                return try await downloadAndLoad(force: false)
            } catch {
                let desc = error.localizedDescription
                if desc.contains("metadata") || desc.contains("invalid") || desc.contains("retrieved from server") {
                    // 旧缓存损坏（如之前时代半路下载导致 metadata 缺服务端字段），清理后完整重下再加载（自愈）
                    return try await downloadAndLoad(force: true)
                }
                throw error
            }
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
                              userInfo: [NSLocalizedDescriptionKey: "本地语音模型下载超时（600s）。首次使用需联网从 HuggingFace(huggingface.co)下载模型(约480MB)，当前网络可能无法访问。如在国内，请开启可访问 huggingface.co 的 VPN 后重试。"])
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
