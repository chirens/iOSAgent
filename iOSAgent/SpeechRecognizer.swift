import Foundation
import Speech
import AVFoundation
import Combine

/// 语音转文字封装，供 ChatView 使用。
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private let _transcript = PassthroughSubject<String, Never>()
    var transcriptPublisher: AnyPublisher<String, Never> { _transcript.eraseToAnyPublisher() }

    init(localeIdentifier: String = "zh-CN") {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        speechRecognizer?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        await MainActor.run {
            self.authorizationStatus = speechStatus
        }

        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        return speechStatus == .authorized && (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
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
                self.transcript = text
                self._transcript.send(text)
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

        await MainActor.run {
            self.isRecording = true
        }
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
