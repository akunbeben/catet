import Foundation
import WhisperKit

/// The one WhisperKit model used for live and saved-audio transcription.
enum WhisperModel {
    private static let name = "openai_whisper-large-v3-v20240930_turbo"

    /// Downloads the CoreML model on first use, then loads it from the local cache.
    static func load() async throws -> WhisperKit {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LiveTranscriptionError.model("The Application Support folder is unavailable.")
        }
        let modelCache = applicationSupport.appendingPathComponent("Catet/models", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: modelCache, withIntermediateDirectories: true)
        } catch {
            throw LiveTranscriptionError.model("Could not create the model cache: \(error.localizedDescription)")
        }
        try Task.checkCancellation()

        do {
            let downloader = ModelDownloader(repoName: "argmaxinc/whisperkit-coreml")
            let components = [
                "AudioEncoder.mlmodelc/**", "TextDecoder.mlmodelc/**",
                "MelSpectrogram.mlmodelc/**", "TextDecoderContextPrefill.mlmodelc/**", "*.json"
            ]
            let repository = try await downloader.resolveRepo(
                patterns: components.map { "\(name)/\($0)" },
                downloadBase: modelCache
            )
            try Task.checkCancellation()
            return try await WhisperKit(
                modelFolder: repository.appendingPathComponent(name).path,
                tokenizerFolder: modelCache,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
        } catch {
            if error is CancellationError { throw error }
            throw LiveTranscriptionError.model(error.localizedDescription)
        }
    }

    /// Transcribes a prepared 16 kHz mono WAV for CatetEngine and writes `{"segments": [...]}`.
    static func transcribeFile(audio: URL, output: URL) async throws {
        let samples: [Float]
        do { samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path) }
        catch { throw LiveTranscriptionError.audio(error.localizedDescription) }
        var segments: [LiveTranscriptSegment] = []
        if !LiveAudioMixer.isSilent(samples[...]) {
            let model = try await load()
            // Detect once from the first speech. Per-chunk detection drifts on short or quiet chunks.
            let frame = LiveAudioMixer.outputSampleRate / 10
            let speechStart = stride(from: 0, to: samples.count, by: frame).first {
                !LiveAudioMixer.isSilent(samples[$0..<min(samples.count, $0 + frame)])
            } ?? 0
            let window = Array(samples[speechStart..<min(samples.count, speechStart + LiveAudioMixer.outputSampleRate * 30)])
            let options = DecodingOptions(
                verbose: false, task: .transcribe,
                language: try await model.detectLangauge(audioArray: window).language,
                usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
                // VAD chunks can start mid-sentence. This threshold drops whole chunks of real speech.
                firstTokenLogProbThreshold: nil,
                chunkingStrategy: .vad
            )
            let results = try await model.transcribe(audioArray: samples, decodeOptions: options)
            for segment in results.flatMap(\.segments) {
                let start = Double(segment.start), end = Double(segment.end)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard start.isFinite, end.isFinite, start >= 0, end > start, !text.isEmpty else { continue }
                let first = min(samples.count, Int(start * Double(LiveAudioMixer.outputSampleRate)))
                let last = min(samples.count, max(first, Int(end * Double(LiveAudioMixer.outputSampleRate))))
                let segment = LiveTranscriptSegment(start: start, end: end, text: text)
                guard !segment.looksHallucinated(speechSeconds: LiveAudioMixer.speechSeconds(samples[first..<last])) else { continue }
                segments.append(segment)
            }
            segments.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        }
        struct Document: Encodable { let segments: [LiveTranscriptSegment] }
        do { try JSONEncoder().encode(Document(segments: segments)).write(to: output, options: .atomic) }
        catch { throw LiveTranscriptionError.persistence(error.localizedDescription) }
    }
}
