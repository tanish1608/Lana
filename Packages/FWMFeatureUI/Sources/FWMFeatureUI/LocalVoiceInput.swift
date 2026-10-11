#if os(iOS)
import Foundation
import Observation
import FinanceAI

@Observable @MainActor
final class LocalVoiceInput {
    var recording = false
    var busy = false
    var status: String?
    private let recorder = VoiceRecorder()
    private let transcriber = OnDeviceSpeechTranscriber()
    private var operation: UUID?
    private var limit: Task<Void, Never>?
    func start() async {
        guard !busy, !recording else { return }
        let id = UUID(); operation = id; busy = true; status = nil
        defer { if operation == id { busy = false } }
        do {
            try await recorder.start()
            guard operation == id else { recorder.cancel(); return }
            recording = true; status = "Recording locally. Tap stop, then review the transcript before sending."
            limit = Task {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, operation == id else { return }
                cancel(); status = "Recording reached 60 seconds. Please record a shorter message."
            }
        } catch { if operation == id { status = error.localizedDescription } }
    }
    func finish() async -> String? {
        guard recording, !busy else { return nil }
        let id = operation; busy = true; recording = false; limit?.cancel()
        defer { if operation == id { busy = false } }
        do {
            let url = try recorder.stop()
            defer { try? FileManager.default.removeItem(at: url) }
            let text = try await transcriber.transcribe(fileURL: url)
            guard operation == id else { return nil }
            status = "Transcribed on device. Review the text before continuing."
            return text
        } catch { if operation == id { status = error.localizedDescription }; return nil }
    }
    func cancel() { operation = nil; limit?.cancel(); recorder.cancel(); transcriber.cancel(); recording = false; busy = false }
}
#endif
