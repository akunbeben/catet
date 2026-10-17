import Foundation
import AVFoundation
import Darwin

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

/// Reads the checkpointed PCM WAV files written by WaveWriter and produces bounded 16 kHz mono windows.
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
    private var microphone: LiveWAVSource?
    private var system: LiveWAVSource?

    init(directory: URL) {
        microphoneURL = directory.appendingPathComponent("microphone.wav")
        systemURL = directory.appendingPathComponent("system.wav")
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
            throw LiveTranscriptionError.audio("The checkpointed WAV does not yet contain the requested samples.")
        }
        let frameCount = Int(endFrame - startFrame)
        guard frameCount > 0 else { return [] }

        let mic = try microphone?.samples(fromOutputFrame: startFrame, count: frameCount) ?? []
        let system = try system?.samples(fromOutputFrame: startFrame, count: frameCount) ?? []
        let micAvailable = microphone?.outputFrameCount ?? 0
        let systemAvailable = self.system?.outputFrameCount ?? 0
        var mixed = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let frame = startFrame + Int64(index)
            let hasMic = frame < micAvailable && !mic.isEmpty
            let hasSystem = frame < systemAvailable && !system.isEmpty
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
            microphone = try LiveWAVSource(url: microphoneURL)
        }
        if system == nil, FileManager.default.fileExists(atPath: systemURL.path) {
            system = try LiveWAVSource(url: systemURL)
        }
        try microphone?.refresh()
        try system?.refresh()
    }
}

private final class LiveWAVSource {
    private static let headerSize: Int64 = 44
    private let url: URL
    private let descriptor: Int32
    private var channels = 0
    private var sampleRate = 0
    private var bytesPerFrame = 0
    private(set) var frameCount: Int64 = 0

    var outputFrameCount: Int64 {
        guard sampleRate > 0 else { return 0 }
        return (frameCount * Int64(LiveAudioMixer.outputSampleRate) + Int64(sampleRate) - 1) / Int64(sampleRate)
    }

    init(url: URL) throws {
        self.url = url
        descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw LiveTranscriptionError.audio("Could not open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        do { try refresh() }
        catch { Darwin.close(descriptor); throw error }
    }

    deinit { Darwin.close(descriptor) }

    func refresh() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ioError("Could not inspect") }
        let fileSize = Int64(info.st_size)
        guard fileSize >= Self.headerSize else { return }

        var header = [UInt8](repeating: 0, count: Int(Self.headerSize))
        let headerRead = header.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress!, $0.count, 0) }
        guard headerRead == header.count else { throw ioError("Could not read WAV header") }
        guard String(bytes: header[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: header[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: header[12..<16], encoding: .ascii) == "fmt ",
              String(bytes: header[36..<40], encoding: .ascii) == "data" else {
            throw LiveTranscriptionError.audio("\(url.lastPathComponent) has an unsupported WAV header.")
        }

        let format = Self.uint16(header, at: 20)
        let channelCount = Int(Self.uint16(header, at: 22))
        let rate = Int(Self.uint32(header, at: 24))
        let bitsPerSample = Int(Self.uint16(header, at: 34))
        guard format == 1, channelCount > 0, rate > 0, bitsPerSample == 16 else {
            throw LiveTranscriptionError.audio("\(url.lastPathComponent) must contain 16-bit PCM samples.")
        }
        channels = channelCount
        sampleRate = rate
        bytesPerFrame = channelCount * 2
        let reportedDataBytes = Int64(Self.uint32(header, at: 40))
        let readableDataBytes = max(0, fileSize - Self.headerSize)
        frameCount = min(reportedDataBytes, readableDataBytes) / Int64(bytesPerFrame)
    }

    func samples(fromOutputFrame startFrame: Int64, count: Int) throws -> [Float] {
        guard count > 0, frameCount > 0 else { return [] }
        let rate = Double(sampleRate)
        let firstRequestedSourceFrame = startFrame * Int64(sampleRate) / Int64(LiveAudioMixer.outputSampleRate)
        guard firstRequestedSourceFrame < frameCount else { return [] }
        let lastOutputFrame = startFrame + Int64(count) - 1
        let lastRequestedSourceFrame = min(frameCount - 1,
                                           lastOutputFrame * Int64(sampleRate) / Int64(LiveAudioMixer.outputSampleRate) + 1)
        let sourceStartFrame = max(0, firstRequestedSourceFrame - 128)
        let sourceEndFrame = min(frameCount, lastRequestedSourceFrame + 129)
        let sourceFrameCount = Int(sourceEndFrame - sourceStartFrame)
        let byteCount = sourceFrameCount * bytesPerFrame
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { throw ioError("Could not allocate WAV samples") }
            var offset = 0
            while offset < byteCount {
                let result = Darwin.pread(descriptor, base.advanced(by: offset), byteCount - offset,
                                          off_t(Self.headerSize + sourceStartFrame * Int64(bytesPerFrame) + Int64(offset)))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw ioError("Could not read WAV samples") }
                offset += result
            }
        }

        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(LiveAudioMixer.outputSampleRate), channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sourceFrameCount)),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(sourceFrameCount) * Double(LiveAudioMixer.outputSampleRate) / rate) + 256)
              ) else {
            throw LiveTranscriptionError.audio("Could not create an audio resampler for \(url.lastPathComponent).")
        }

        input.frameLength = AVAudioFrameCount(sourceFrameCount)
        guard let destination = input.floatChannelData?[0] else {
            throw LiveTranscriptionError.audio("Could not allocate an input audio buffer for \(url.lastPathComponent).")
        }
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<sourceFrameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let offset = frame * bytesPerFrame + channel * 2
                    let word = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    sum += Float(Int16(bitPattern: word)) / 32768
                }
                destination[frame] = sum / Float(channels)
            }
        }
        converter.primeMethod = .none
        var inputProvided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !inputProvided else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputProvided = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            let reason = conversionError?.localizedDescription ?? "unknown conversion error"
            throw LiveTranscriptionError.audio("Could not resample \(url.lastPathComponent): \(reason)")
        }
        guard let converted = output.floatChannelData?[0], output.frameLength > 0 else {
            throw LiveTranscriptionError.audio("The resampler returned no samples for \(url.lastPathComponent).")
        }

        let convertedCount = Int(output.frameLength)
        let convertedStart = Double(sourceStartFrame) * Double(LiveAudioMixer.outputSampleRate) / rate
        var outputSamples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(startFrame + Int64(index)) - convertedStart
            let lower = Int(floor(position))
            guard lower >= 0, lower < convertedCount else { continue }
            let upper = min(lower + 1, convertedCount - 1)
            let fraction = Float(position - Double(lower))
            outputSamples[index] = converted[lower] + (converted[upper] - converted[lower]) * fraction
        }
        return outputSamples
    }

    private func ioError(_ operation: String) -> LiveTranscriptionError {
        .audio("\(operation) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
