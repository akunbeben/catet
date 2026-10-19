import Foundation

struct LiveTranscriptSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum LiveAudioWindow {
    static func absoluteSegments(
        _ relativeSegments: [LiveTranscriptSegment],
        contextStartFrame: Int64,
        cursorFrame: Int64,
        recordingEndFrame: Int64
    ) throws -> [LiveTranscriptSegment] {
        guard contextStartFrame >= 0, cursorFrame >= contextStartFrame, recordingEndFrame >= cursorFrame else {
            throw LiveTranscriptionError.audio("The transcription window has an invalid sample range.")
        }
        let rate = Double(LiveAudioMixer.outputSampleRate)
        let offset = Double(contextStartFrame) / rate
        let cursor = Double(cursorFrame) / rate
        let recordingEnd = Double(recordingEndFrame) / rate
        var absolute: [LiveTranscriptSegment] = []
        for segment in relativeSegments {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end >= segment.start else {
                throw LiveTranscriptionError.inference("WhisperKit returned invalid segment timestamps.")
            }
            let start = offset + segment.start
            let unclampedEnd = offset + segment.end
            guard start.isFinite, unclampedEnd.isFinite else {
                throw LiveTranscriptionError.inference("WhisperKit returned invalid segment timestamps.")
            }
            let clippedStart = max(start, cursor)
            let clippedEnd = min(unclampedEnd, recordingEnd)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clippedStart < recordingEnd, clippedEnd > clippedStart, !text.isEmpty else { continue }
            absolute.append(LiveTranscriptSegment(start: clippedStart, end: clippedEnd, text: text))
        }
        return absolute.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
}

enum LiveTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case noSpeech
    case audio(String)
    case model(String)
    case inference(String)
    case persistence(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noSpeech:
            return "No speech was detected. Check the audio source and try another recording."
        case .audio(let message):
            return "The recording audio could not be read: \(message)"
        case .model(let message):
            return "The transcription model could not be prepared. Check your internet connection and available storage, then stop and retry. \(message)"
        case .inference(let message):
            return "The recording was saved, but transcription failed. Try transcribing it again. \(message)"
        case .persistence(let message):
            return "The transcript could not be saved. The audio recording is still available. \(message)"
        case .cancelled:
            return "Transcription was cancelled. The audio recording is still available."
        }
    }
}

struct LiveSegmentConfirmation {
    private(set) var confirmed: [LiveTranscriptSegment] = []
    private(set) var pending: [LiveTranscriptSegment] = []

    mutating func replacePending(with segments: [LiveTranscriptSegment], confirmingPrefix count: Int) -> LiveTranscriptSegment? {
        let ordered = segments
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let commitCount = min(max(0, count), ordered.count)
        let newlyConfirmed = Array(ordered.prefix(commitCount))
        confirmed.append(contentsOf: newlyConfirmed)
        pending = Array(ordered.dropFirst(commitCount))
        return newlyConfirmed.last
    }


    mutating func finalizedSegments() throws -> [LiveTranscriptSegment] {
        confirmed.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        guard !confirmed.isEmpty else { throw LiveTranscriptionError.noSpeech }
        return confirmed
    }

    var allSegments: [LiveTranscriptSegment] { confirmed + pending }
}

/// Reads complete pages from the growing Ogg Opus capture files into bounded 16 kHz windows.
final class LiveAudioMixer {
    static let outputSampleRate = 16_000

    static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        let frameLength = outputSampleRate / 10
        var energy: Double = 0
        var frameCount = 0
        for sample in samples {
            energy += Double(sample) * Double(sample)
            frameCount += 1
            if frameCount == frameLength {
                if sqrt(energy / Double(frameCount)) >= 0.005 { return false }
                energy = 0
                frameCount = 0
            }
        }
        return frameCount == 0 || sqrt(energy / Double(frameCount)) < 0.005
    }

    private let microphoneURL: URL
    private let systemURL: URL
    private var microphone: LiveAudioSource?
    private var system: LiveAudioSource?

    init(directory: URL) {
        microphoneURL = directory.appendingPathComponent("microphone.ogg")
        systemURL = directory.appendingPathComponent("system.ogg")
    }

    func availableFrameCount() throws -> Int64 {
        try refreshSources()
        return max(microphone?.outputFrameCount ?? 0, system?.outputFrameCount ?? 0)
    }

    func read(fromFrame startFrame: Int64, toFrame endFrame: Int64) throws -> [Float] {
        guard startFrame >= 0, endFrame >= startFrame,
              endFrame - startFrame <= Int64(Self.outputSampleRate * 30) else {
            throw LiveTranscriptionError.audio("Requested audio window is outside the supported bounds.")
        }
        try refreshSources()
        let available = max(microphone?.outputFrameCount ?? 0, system?.outputFrameCount ?? 0)
        guard endFrame <= available else {
            throw LiveTranscriptionError.audio("The Ogg recording does not yet contain the requested samples.")
        }
        let frameCount = Int(endFrame - startFrame)
        guard frameCount > 0 else { return [] }

        let micAvailable = microphone?.outputFrameCount ?? 0
        let systemAvailable = system?.outputFrameCount ?? 0
        let mic = try microphone?.samples(fromOutputFrame: startFrame, count: frameCount) ?? []
        let system = try self.system?.samples(fromOutputFrame: startFrame, count: frameCount) ?? []
        var mixed = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let frame = startFrame + Int64(index)
            let hasMic = frame < micAvailable && index < mic.count
            let hasSystem = frame < systemAvailable && index < system.count
            if hasMic && hasSystem {
                mixed[index] = min(1, max(-1, (mic[index] + system[index]) * 0.5))
            } else if hasMic {
                mixed[index] = mic[index]
            } else if hasSystem {
                mixed[index] = system[index]
            }
        }
        return mixed
    }

    private func refreshSources() throws {
        if microphone == nil, FileManager.default.fileExists(atPath: microphoneURL.path) {
            microphone = LiveAudioSource(url: microphoneURL)
        }
        if system == nil, FileManager.default.fileExists(atPath: systemURL.path) {
            system = LiveAudioSource(url: systemURL)
        }
        try microphone?.refresh()
        try system?.refresh()
    }
}

private final class LiveAudioSource {
    private static let maximumDiagnosticBytes = 16 * 1024

    private let url: URL
    private var publishedFrames: Int64 = 0

    var outputFrameCount: Int64 {
        // Match FFmpeg's nearest-sample resampling at the final Opus granule.
        (publishedFrames * Int64(LiveAudioMixer.outputSampleRate) + 24_000) / 48_000
    }

    init(url: URL) { self.url = url }

    func refresh() throws {
        publishedFrames = try AudioFile.frameCount(at: url)
    }

    func samples(fromOutputFrame startFrame: Int64, count: Int) throws -> [Float] {
        guard count > 0, startFrame < outputFrameCount else { return [] }
        let availableCount = min(Int64(count), outputFrameCount - startFrame)
        let exactCount = Int(availableCount)
        let seconds = Double(startFrame) / Double(LiveAudioMixer.outputSampleRate)
        let duration = Double(exactCount) / Double(LiveAudioMixer.outputSampleRate)
        let seekStart = max(0, seconds - 0.12)
        let ffmpeg: URL
        do {
            ffmpeg = try RuntimeConfig.load().ffmpeg
        } catch {
            throw LiveTranscriptionError.audio("Could not locate FFmpeg to decode \(url.lastPathComponent): \(error.localizedDescription)")
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = ffmpeg
        // Decode bounded preroll to restore Opus state, then trim to the exact requested time.
        process.arguments = [
            "-hide_banner", "-nostdin", "-v", "error",
            "-ss", String(format: "%.9f", seekStart), "-i", url.path,
            "-ss", String(format: "%.9f", seconds - seekStart),
            "-t", String(format: "%.9f", duration),
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"
        ]
        process.standardOutput = output
        process.standardError = errors

        let diagnosticLock = NSLock()
        var diagnostics = Data()
        let drained = DispatchSemaphore(value: 0)
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            errors.fileHandleForReading.closeFile()
            errors.fileHandleForWriting.closeFile()
            throw LiveTranscriptionError.audio("Could not start FFmpeg for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos: .utility).async {
            let handle = errors.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                diagnosticLock.lock()
                if diagnostics.count < Self.maximumDiagnosticBytes {
                    diagnostics.append(data.prefix(Self.maximumDiagnosticBytes - diagnostics.count))
                }
                diagnosticLock.unlock()
            }
            drained.signal()
        }

        let maximumOutputBytes = exactCount * MemoryLayout<Float>.size + 4_096
        var decoded = Data()
        var exceededOutputLimit = false
        do {
            let handle = output.fileHandleForReading
            while let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                guard !exceededOutputLimit else { continue }
                guard decoded.count + chunk.count <= maximumOutputBytes else {
                    exceededOutputLimit = true
                    if process.isRunning { process.terminate() }
                    continue
                }
                decoded.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            drained.wait()
            throw LiveTranscriptionError.audio("Could not read FFmpeg output for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        drained.wait()
        guard !exceededOutputLimit else {
            throw LiveTranscriptionError.audio("FFmpeg returned excessive audio data for \(url.lastPathComponent).")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            diagnosticLock.lock()
            let message = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            diagnosticLock.unlock()
            let detail = message.isEmpty ? "FFmpeg exited with status \(process.terminationStatus)." : message
            throw LiveTranscriptionError.audio("Could not decode \(url.lastPathComponent): \(detail)")
        }
        guard decoded.count % MemoryLayout<Float>.size == 0 else {
            throw LiveTranscriptionError.audio("FFmpeg returned incomplete samples for \(url.lastPathComponent).")
        }
        let sampleCount = decoded.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else {
            throw LiveTranscriptionError.audio("FFmpeg returned no samples for \(url.lastPathComponent).")
        }
        let samples = decoded.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard sampleCount >= exactCount else {
            throw LiveTranscriptionError.audio(
                "FFmpeg decoded only \(sampleCount) of \(exactCount) requested samples from \(url.lastPathComponent)."
            )
        }
        return sampleCount == exactCount ? samples : Array(samples.prefix(exactCount))
    }
}
