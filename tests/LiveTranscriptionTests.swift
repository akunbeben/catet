import Foundation

struct LiveTranscriptionTestFailure: Error { let message: String }

@main
struct LiveTranscriptionTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw LiveTranscriptionTestFailure(message: message) }
    }

    static func append(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    static func wav(sampleRate: UInt32, channels: UInt16, samples: [Int16], headerFrames: UInt32) -> Data {
        let block = channels * 2
        var data = Data("RIFF".utf8)
        append(headerFrames * UInt32(block) + 36, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channels, to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(block), to: &data)
        append(block, to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(headerFrames * UInt32(block), to: &data)
        for sample in samples { append(UInt16(bitPattern: sample), to: &data) }
        return data
    }

    static func updateDataLength(_ url: URL, frames: UInt32, channels: UInt16) throws {
        var riffSize = Data()
        append(frames * UInt32(channels * 2) + 36, to: &riffSize)
        var dataSize = Data()
        append(frames * UInt32(channels * 2), to: &dataSize)
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: 4)
        try file.write(contentsOf: riffSize)
        try file.seek(toOffset: 40)
        try file.write(contentsOf: dataSize)
        try file.close()
    }
    static func testCheckpointedAudioAndMixAlignment(in directory: URL) throws {
        let micURL = directory.appendingPathComponent("microphone.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let micSamples = (0..<16_000).flatMap { _ in [Int16(8192), Int16(16384)] }
        let systemSamples = [Int16](repeating: 4096, count: 8_000)
        try wav(sampleRate: 16_000, channels: 2, samples: micSamples, headerFrames: 8_000).write(to: micURL)
        try wav(sampleRate: 8_000, channels: 1, samples: systemSamples, headerFrames: 8_000).write(to: systemURL)

        let mixer = LiveAudioMixer(directory: directory)
        try check(try mixer.availableFrameCount() == 16_000, "WAV frame counts must be resampled onto the shared 16 kHz timeline")
        let firstWindow = try mixer.read(fromFrame: 4_000, toFrame: 4_008)
        let nextWindow = try mixer.read(fromFrame: 8_000, toFrame: 8_008)
        try check(firstWindow.count == 8 && nextWindow.count == 8, "Each bounded read must return only its requested sample window")
        try check(firstWindow.allSatisfy { abs($0 - 0.25) < 0.01 }, "Stereo mic downmix and aligned system audio must be averaged together")
        try check(nextWindow.allSatisfy { abs($0 - 0.125) < 0.01 }, "Samples beyond the mic checkpoint must use the aligned system source only")
        let afterMicrophoneEnds = try mixer.read(fromFrame: 12_000, toFrame: 12_008)
        try check(afterMicrophoneEnds.allSatisfy { abs($0 - 0.125) < 0.01 },
                  "A source that stopped earlier must leave the remaining source readable")

        try updateDataLength(micURL, frames: 16_000, channels: 2)
        let checkpointedTail = try mixer.read(fromFrame: 8_000, toFrame: 8_008)
        try check(checkpointedTail.allSatisfy { abs($0 - 0.25) < 0.01 }, "A growing WAV reader must observe the next checkpoint without replaying earlier frames")
        print("PASS: Bounded checkpointed WAV reads downmix and align different source rates")
    }

    static func testSegmentConfirmationAndSilence() throws {
        var confirmation = LiveSegmentConfirmation()
        _ = confirmation.replacePending(with: [], confirmingPrefix: 0)
        try check(confirmation.allSegments.isEmpty, "Silent polling windows must remain valid without inventing transcript text")

        let hello = LiveTranscriptSegment(start: 0, end: 0.9, text: "Hello.")
        let there = LiveTranscriptSegment(start: 1.1, end: 1.9, text: "There.")
        _ = confirmation.replacePending(with: [hello, there], confirmingPrefix: 0)
        try check(confirmation.confirmed.isEmpty && confirmation.pending == [hello, there], "The latest two segments must remain unconfirmed like WhisperKit streaming")

        let again = LiveTranscriptSegment(start: 2.1, end: 2.8, text: "Again.")
        let finished = LiveTranscriptSegment(start: 3.1, end: 4.0, text: "Finished.")
        _ = confirmation.replacePending(with: [hello, there, again, finished], confirmingPrefix: 2)
        try check(confirmation.confirmed == [hello, there], "A re-decoded pending window must confirm its stable prefix")
        try check(confirmation.pending == [again, finished], "The recent two segments must stay in the live preview until finalization")
        let final = try confirmation.finalizedSegments()
        try check(final == [hello, there, again, finished], "Finalization must flush every remaining segment in timestamp order")

        var boundary = LiveSegmentConfirmation()
        _ = boundary.replacePending(with: [LiveTranscriptSegment(start: 20, end: 22, text: "We should")], confirmingPrefix: 0)
        let revised = LiveTranscriptSegment(start: 20.1, end: 23, text: "We should keep going")
        _ = boundary.replacePending(with: [revised], confirmingPrefix: 0)
        try check(boundary.pending == [revised], "A re-decoded suffix replaces its earlier hypothesis without fuzzy concatenation")

        let quietSamples = [Float](repeating: 0, count: 8)
        let voicedSamples: [Float] = [0.02, -0.02, 0.03, -0.03]
        try check(LiveAudioMixer.isSilent(quietSamples[...]) && !LiveAudioMixer.isSilent(voicedSamples[...]), "Only a truly silent unconfirmed window may advance without transcript segments")
        var sparseSpeech = [Float](repeating: 0, count: LiveAudioMixer.outputSampleRate * 29)
        sparseSpeech.replaceSubrange(16_000..<17_600, with: repeatElement(Float(0.02), count: 1_600))
        try check(!LiveAudioMixer.isSilent(sparseSpeech[...]),
                  "A brief utterance between long pauses must remain available for transcription")
        var silence = LiveSegmentConfirmation()
        _ = silence.replacePending(with: [], confirmingPrefix: 0)
        do {
            _ = try silence.finalizedSegments()
            throw LiveTranscriptionTestFailure(message: "A silent recording must not be reported as a successful empty transcript")
        } catch LiveTranscriptionError.noSpeech { }
        print("PASS: Streaming confirmation retains its tail, replaces boundary hypotheses, and rejects empty success")
    }

    static func testAbsoluteSegmentMapping() throws {
        let rate = Int64(LiveAudioMixer.outputSampleRate)
        let contextStart = 300 * rate
        let cursor = contextStart + 2 * rate
        let recordingEnd = contextStart + 6 * rate
        let relative = [
            LiveTranscriptSegment(start: 0, end: 1, text: "Committed context"),
            LiveTranscriptSegment(start: 2, end: 3, text: "Pending at five minutes"),
            LiveTranscriptSegment(start: 5.5, end: 7, text: "Speech at the recording edge"),
            LiveTranscriptSegment(start: 6.2, end: 6.5, text: "Padded silence")
        ]
        let absolute = try LiveAudioWindow.absoluteSegments(relative, contextStartFrame: contextStart,
                                                            cursorFrame: cursor, recordingEndFrame: recordingEnd)
        try check(absolute.count == 2, "Timestamp mapping must exclude committed context and padded-only speech")
        try check(abs(absolute[0].start - 302) < 0.001 && abs(absolute[0].end - 303) < 0.001,
                  "A nonzero audio-window offset must preserve segment timestamps")
        try check(abs(absolute[1].start - 305.5) < 0.001 && abs(absolute[1].end - 306) < 0.001,
                  "Segment end times must clamp to the true WAV recording duration")

        do {
            _ = try LiveAudioWindow.absoluteSegments([LiveTranscriptSegment(start: 2, end: 1, text: "Invalid")],
                                                      contextStartFrame: contextStart, cursorFrame: cursor,
                                                      recordingEndFrame: recordingEnd)
            throw LiveTranscriptionTestFailure(message: "Invalid SDK timestamps must fail instead of entering the final transcript")
        } catch LiveTranscriptionError.inference(_) { }
        print("PASS: Nonzero window timestamps and final-tail bounds remain continuous")
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catet-live-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try testCheckpointedAudioAndMixAlignment(in: directory)
        try testSegmentConfirmationAndSilence()
        try testAbsoluteSegmentMapping()
        print("All live-transcription regressions passed.")
    }
}
