import Foundation
import Speech
import AVFoundation

/// Recognizes a recorded file locally. Rejects unsupported locales/devices instead
/// of falling back to server transcription. The host owns and deletes the audio file.
@MainActor
public final class OnDeviceSpeechTranscriber {
    private var recognition: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var operationID: UUID?
    public init() {}

    public func transcribe(fileURL: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> String {
        guard fileURL.isFileURL else { throw FinanceAIError.invalidInput }
        guard operationID == nil else { throw FinanceAIError.unavailable("A transcription is already in progress.") }
        let id = UUID()
        operationID = id
        let allowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard operationID == id else { throw CancellationError() }
        guard allowed else { operationID = nil; throw FinanceAIError.unavailable("Allow Speech Recognition in Settings.") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            operationID = nil
            throw FinanceAIError.unavailable("On-device speech is unavailable for this device or language.")
        }
        do { try Task.checkCancellation() } catch { operationID = nil; throw error }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    let failed = error != nil
                    Task { @MainActor [weak self] in
                        if final, let text, !text.isEmpty {
                            self?.finish(id: id, result: .success(text))
                        } else if failed {
                            self?.finish(id: id, result: .failure(FinanceAIError.unavailable("Local transcription failed. Try recording again.")))
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(30))
                        self?.finish(id: id, result: .failure(FinanceAIError.unavailable("Local transcription timed out.")))
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }
    public func cancel() {
        if let id = operationID { finish(id: id, result: .failure(CancellationError())) }
    }
    private func finish(id: UUID, result: Result<String, any Error>) {
        guard operationID == id else { return }
        let continuation = self.continuation
        self.continuation = nil
        operationID = nil
        timeout?.cancel()
        timeout = nil
        recognition?.cancel()
        recognition = nil
        continuation?.resume(with: result)
    }
}

#if os(iOS)
/// Push-to-talk recorder. Audio is temporary local data, never a cloud upload.
@MainActor
public final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var preparingID: UUID?
    public init() {}
    public var isRecording: Bool { recorder?.isRecording == true }

    public func start() async throws {
        guard recorder == nil, preparingID == nil else { throw FinanceAIError.unavailable("Recording is already active.") }
        let id = UUID()
        preparingID = id
        defer { if preparingID == id { preparingID = nil } }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard preparingID == id else { throw CancellationError() }
        guard allowed else { throw FinanceAIError.unavailable("Allow microphone access in Settings.") }
        try Task.checkCancellation()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement)
        try audio.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID()).m4a")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            guard recorder.record(forDuration: 60) else { throw FinanceAIError.unavailable("Could not start audio recording.") }
            self.recorder = recorder
            file = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }
    /// Caller must delete the file after transcription, including on errors.
    public func stop() throws -> URL {
        guard let recorder, let file else { throw FinanceAIError.unavailable("No recording is active.") }
        recorder.stop()
        self.recorder = nil
        self.file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return file
    }
    public func cancel() {
        preparingID = nil
        if let url = try? stop() { try? FileManager.default.removeItem(at: url) }
    }
}
#endif
