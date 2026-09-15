import Foundation
import Speech
import AVFoundation

/// 语音转文字封装，供 ChatView 使用。
@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init(localeIdentifier: String = "zh-CN") {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        speechRecognizer?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        self.authorizationStatus = speechStatus
        return speechStatus == .authorized
    }

    func startRecording() async throws {
        guard await requestAuthorization() else {
            throw RecognizerError.notAuthorized
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw RecognizerError.unavailable
        }

        reset()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = text
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    self.stopRecording()
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        self.isRecording = true
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        isRecording = false
    }

    func reset() {
        stopRecording()
        transcript = ""
    }

    /// 对录音文件做一次性识别：使用系统 SFSpeechRecognizer（作为 WhisperKit 失败后的兜底）。
    func transcribeFile(url: URL) async throws -> String {
        guard await requestAuthorization() else { throw RecognizerError.notAuthorized }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { throw RecognizerError.unavailable }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = false
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    self?.recognitionTask = nil
                    return
                }
                if let result = result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    self?.recognitionTask = nil
                }
            }
        }
    }

    enum RecognizerError: Error, LocalizedError {
        case notAuthorized
        case unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "需要语音和麦克风权限，请在系统设置中开启。"
            case .unavailable: return "当前设备或地区不支持语音识别。"
            }
        }
    }
}

extension SpeechRecognizer: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        // 可用性变化时暂不处理，调用处会检查 isAvailable
    }
}

// MARK: - 按住说话录音器

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordStartTime: Date?

    /// 录音文件统一放到 Application Support，比 NSTemporaryDirectory 更稳定，不会被系统随时清理。
    private var recordingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 原始录音文件路径（覆盖写，避免残留）
    private var rawRecordURL: URL {
        recordingsDir.appendingPathComponent("iosagent_recording_raw.m4a")
    }

    /// 当前正在录制中的文件 URL（stop 前有效）
    var currentRecordingURL: URL? { recordingURL }

    func start() async {
        do {
            let session = AVAudioSession.sharedInstance()
            let granted = await requestPermission()
            guard granted else {
                errorMessage = "需要麦克风权限"
                return
            }
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let url = rawRecordURL
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.record()
            recordingURL = url
            recordStartTime = Date()
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
            recordingURL = nil
            recordStartTime = nil
        }
    }

    /// 停止录音。返回的文件位于 Application Support，文件名唯一，便于异步转写时不会被并发删除。
    /// 返回值 nil 表示没有有效录音。
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        isRecording = false
        guard let src = recordingURL else { return nil }
        recordingURL = nil
        recordStartTime = nil

        // 录音太短（< 0.3s）视为无效
        let duration = recorder?.currentTime ?? 0
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: src)
            return nil
        }

        // 拷贝到唯一路径，避免原始路径被下一次 start() 覆盖或 defer 误删
        let dst = recordingsDir.appendingPathComponent("iosagent_recording_\(UUID().uuidString).m4a")
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch {
            // 拷贝失败则回退返回原始路径
            return src
        }
    }

    /// 回收录音文件（转写完成后调用）
    func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {}
}
