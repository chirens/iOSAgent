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

        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        return speechStatus == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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

    /// 对录音文件做一次性识别（服务端失败后的回退）
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

    private var recordURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iosagent_recording.m4a")
    }

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
            let url = recordURL
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.record()
            recordingURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        isRecording = false
        return recordingURL
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
