import Foundation
import WhisperKit

actor LiveTranscription {
    enum Status: Sendable, Equatable {
        case idle
        case preparingModel
        case transcribing
        case ready
        case failed(String)
        case cancelled
    }

    private(set) var status: Status = .idle

    private static let sampleRate = LiveAudioMixer.outputSampleRate
    private static let minimumNewAudioFrames = sampleRate * 20
    private static let windowFrames = sampleRate * 29
    private static let contextFrames = sampleRate * 2
    private static let modelName = "openai_whisper-large-v3-v20240930_turbo"

    private let directory: URL
    private let mixer: LiveAudioMixer
    private var model: WhisperKit?
    private var worker: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var started = false
    private var finishing = false
    private var cancelled = false
    private var finished = false
    private var nextWindowStartFrame: Int64 = 0
    private var lastInferenceEndFrame: Int64?
    private var segmentConfirmation = LiveSegmentConfirmation()
    private var terminalError: LiveTranscriptionError?

    init(directory: URL) {
        self.directory = directory
        mixer = LiveAudioMixer(directory: directory)
    }

    /// Starts model preparation in the background so recording can continue immediately.
    func start() async {
        guard !started else { return }
        started = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try removeFinalOutputs()
            try removePreviews()
        } catch {
            fail(.persistence(error.localizedDescription))
            return
        }

        status = .preparingModel
        worker = Task { [weak self] in
            guard let self else { return }
            await self.runWorker()
        }
    }

    /// Stops periodic processing, transcribes the final tail, and publishes complete engine outputs.
    func finish() async throws {
        guard started else { throw LiveTranscriptionError.inference("Transcription was not started.") }
        if finished { return }
        if cancelled { throw LiveTranscriptionError.cancelled }
        if let terminalError { throw terminalError }

        finishing = true
        if finalizationTask == nil {
            finalizationTask = Task { [weak self] in
                guard let self else { return }
                await self.finalizeRecording()
            }
        }
        if let finalizationTask { await finalizationTask.value }
        if let terminalError { throw terminalError }
        if cancelled { throw LiveTranscriptionError.cancelled }
        guard finished else { throw LiveTranscriptionError.inference("Final transcription did not complete.") }
    }

    /// Waits for transcription to stop and removes previews without touching recorded audio.
    func cancel() async {
        guard !finished else { return }
        cancelled = true
        worker?.cancel()
        finalizationTask?.cancel()
        if let finalizationTask { await finalizationTask.value }
        if let worker { await worker.value }
        do {
            try removePreviews()
            try removeFinalOutputs()
            status = .cancelled
        } catch {
            fail(.persistence("Could not remove live transcription outputs: \(error.localizedDescription)"))
        }
    }

    private func finalizeRecording() async {
        if let worker { await worker.value }
        guard !cancelled else { return }
        if terminalError != nil { return }
        do {
            try Task.checkCancellation()
            try await loadModelIfNeeded()
            status = .transcribing
            try await processWindows(final: true)
            try Task.checkCancellation()
            guard !cancelled else { return }
            let segments = try segmentConfirmation.finalizedSegments()
            try removePreviews()
            try publish(segments)
            finished = true
            status = .ready
        } catch is CancellationError {
            if !cancelled { fail(.inference("Final transcription was interrupted.")) }
        } catch let error as LiveTranscriptionError {
            if !cancelled { fail(error) }
        } catch {
            if !cancelled { fail(.inference(error.localizedDescription)) }
        }
    }

    private func runWorker() async {
        do {
            try Task.checkCancellation()
            guard !cancelled else { return }
            try await loadModelIfNeeded()
            while !finishing && !cancelled {
                try Task.checkCancellation()
                try await processWindows(final: false)
                if !finishing && !cancelled { status = .ready }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch is CancellationError {
            if !cancelled && !finishing { fail(.inference("Background transcription was interrupted.")) }
        } catch let error as LiveTranscriptionError {
            if !cancelled { fail(error) }
        } catch {
            if !cancelled { fail(.inference(error.localizedDescription)) }
        }
    }

    private func loadModelIfNeeded() async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard model == nil else { return }
        status = .preparingModel
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
        guard !cancelled else { throw CancellationError() }

        do {
            let downloader = ModelDownloader(repoName: "argmaxinc/whisperkit-coreml")
            let components = [
                "AudioEncoder.mlmodelc/**", "TextDecoder.mlmodelc/**",
                "MelSpectrogram.mlmodelc/**", "TextDecoderContextPrefill.mlmodelc/**", "*.json"
            ]
            let repository = try await downloader.resolveRepo(
                patterns: components.map { "\(Self.modelName)/\($0)" },
                downloadBase: modelCache
            )
            try Task.checkCancellation()
            model = try await WhisperKit(
                modelFolder: repository.appendingPathComponent(Self.modelName).path,
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

    private func processWindows(final: Bool) async throws {
        while true {
            try Task.checkCancellation()
            let availableFrames: Int64
            do { availableFrames = try mixer.availableFrameCount() }
            catch let error as LiveTranscriptionError { throw error }
            catch { throw LiveTranscriptionError.audio(error.localizedDescription) }

            let cursor = nextWindowStartFrame
            guard cursor < availableFrames else { return }
            let contextStart = max(0, cursor - Int64(Self.contextFrames))
            let maximumEnd = contextStart + Int64(Self.windowFrames)
            let endFrame = min(maximumEnd, availableFrames)
            guard endFrame > cursor else { return }
            let windowIsFull = endFrame == maximumEnd
            guard final || availableFrames - cursor >= Int64(Self.minimumNewAudioFrames) else { return }
            if !final, let lastInferenceEndFrame {
                let newlyAvailableFrames = endFrame - lastInferenceEndFrame
                guard newlyAvailableFrames > 0,
                      newlyAvailableFrames >= Int64(Self.minimumNewAudioFrames) || windowIsFull else { return }
            }

            let audio: [Float]
            do { audio = try mixer.read(fromFrame: contextStart, toFrame: endFrame) }
            catch let error as LiveTranscriptionError { throw error }
            catch { throw LiveTranscriptionError.audio(error.localizedDescription) }
            guard !audio.isEmpty else { return }
            let reachesRecordingEnd = endFrame == availableFrames
            if LiveAudioMixer.isSilent(audio[Int(cursor - contextStart)..<Int(endFrame - contextStart)]) {
                _ = segmentConfirmation.replacePending(with: [], confirmingPrefix: 0)
                nextWindowStartFrame = final && reachesRecordingEnd
                    ? availableFrames
                    : max(cursor, endFrame - Int64(Self.contextFrames))
                lastInferenceEndFrame = endFrame
                try writePreview(segmentConfirmation.allSegments)
                if final && !reachesRecordingEnd { continue }
                return
            }

            status = .transcribing
            guard let model else { throw LiveTranscriptionError.model("The WhisperKit model is not loaded.") }
            var options = DecodingOptions(
                verbose: false, task: .transcribe, usePrefillPrompt: true,
                detectLanguage: true, skipSpecialTokens: true,
                windowClipTime: min(1, Float(endFrame - cursor) / Float(Self.sampleRate) / 2)
            )
            options.clipTimestamps = [Float(Double(cursor - contextStart) / Double(Self.sampleRate))]
            let results: [TranscriptionResult]
            do {
                results = try await model.transcribe(audioArray: audio, decodeOptions: options)
            } catch {
                if error is CancellationError { throw error }
                throw LiveTranscriptionError.inference(error.localizedDescription)
            }
            if cancelled || (finishing && !final) { return }

            let relativeSegments = results.flatMap(\.segments).map {
                LiveTranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
            }
            let segments = try LiveAudioWindow.absoluteSegments(relativeSegments,
                                                                contextStartFrame: contextStart,
                                                                cursorFrame: cursor,
                                                                recordingEndFrame: endFrame)

            lastInferenceEndFrame = endFrame
            if final && reachesRecordingEnd {
                let unconfirmedStart = Int(cursor - contextStart)
                let unconfirmedEnd = Int(endFrame - contextStart)
                if segments.isEmpty && !LiveAudioMixer.isSilent(audio[unconfirmedStart..<unconfirmedEnd]) {
                    throw LiveTranscriptionError.inference("WhisperKit returned no speech for a non-silent final audio tail. The recording is saved; try transcribing it again.")
                }
                _ = segmentConfirmation.replacePending(with: segments, confirmingPrefix: segments.count)
                nextWindowStartFrame = availableFrames
                try writePreview(segmentConfirmation.allSegments)
                return
            }

            let confirmCount = segments.count > 2
                ? segments.count - 2
                : (windowIsFull && !segments.isEmpty ? 1 : 0)
            let newlyConfirmed = segmentConfirmation.replacePending(with: segments, confirmingPrefix: confirmCount)
            if let newlyConfirmed {
                nextWindowStartFrame = max(cursor, Int64(ceil(newlyConfirmed.end * Double(Self.sampleRate))))
            } else if segments.isEmpty {
                let unconfirmedAudio = audio.dropFirst(Int(cursor - contextStart))
                if LiveAudioMixer.isSilent(unconfirmedAudio) {
                    nextWindowStartFrame = max(cursor, endFrame - Int64(Self.contextFrames))
                } else if windowIsFull {
                    throw LiveTranscriptionError.inference("WhisperKit found no speech in a full non-silent audio window. The recording is saved; try transcribing it again.")
                }
            }
            try writePreview(segmentConfirmation.allSegments)
            if cancelled || (finishing && !final) { return }
            if !final { return }
        }
    }

    private func writePreview(_ segments: [LiveTranscriptSegment]) throws {
        do {
            try atomicWrite(try encodedSegments(segments), to: directory.appendingPathComponent("live-transcript.json"))
            try atomicWrite(Data(transcriptText(segments).utf8), to: directory.appendingPathComponent("live-transcript.txt"))
        } catch {
            throw LiveTranscriptionError.persistence("Could not update the live preview: \(error.localizedDescription)")
        }
    }

    private func publish(_ segments: [LiveTranscriptSegment]) throws {
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let textURL = directory.appendingPathComponent("transcript.txt")
        do {
            try atomicWrite(try encodedSegments(segments), to: jsonURL)
            try atomicWrite(Data(transcriptText(segments).utf8), to: textURL)
        } catch {
            let original = error.localizedDescription
            do { try removeFinalOutputs() }
            catch {
                throw LiveTranscriptionError.persistence("\(original) Cleanup also failed: \(error.localizedDescription)")
            }
            throw LiveTranscriptionError.persistence(original)
        }
    }

    private func encodedSegments(_ segments: [LiveTranscriptSegment]) throws -> Data {
        struct Document: Encodable { let segments: [LiveTranscriptSegment] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(Document(segments: segments))
        data.append(0x0a)
        return data
    }

    private func transcriptText(_ segments: [LiveTranscriptSegment]) -> String {
        segments.map { "[\(formatTime($0.start)) - \(formatTime($0.end))] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n") + "\n"
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalMilliseconds = Int64((seconds * 1000).rounded(.toNearestOrEven))
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let wholeSeconds = totalMilliseconds / 1_000 % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, wholeSeconds, milliseconds)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        do { try data.write(to: destination, options: .atomic) }
        catch { throw LiveTranscriptionError.persistence("Could not write \(destination.lastPathComponent): \(error.localizedDescription)") }
    }

    private func removePreviews() throws {
        try removeIfPresent(directory.appendingPathComponent("live-transcript.json"))
        try removeIfPresent(directory.appendingPathComponent("live-transcript.txt"))
    }

    private func removeFinalOutputs() throws {
        try removeIfPresent(directory.appendingPathComponent("transcript.json"))
        try removeIfPresent(directory.appendingPathComponent("transcript.txt"))
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw LiveTranscriptionError.persistence("Could not remove \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private func fail(_ error: LiveTranscriptionError) {
        terminalError = error
        status = .failed(error.localizedDescription)
    }
}
