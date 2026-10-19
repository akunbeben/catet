import Foundation

struct LiveTranscriptionTestFailure: Error { let message: String }

@main
struct LiveTranscriptionTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw LiveTranscriptionTestFailure(message: message) }
    }

    static func encodeOgg(_ url: URL, expression: String, duration: String, channels: Int = 1, sampleCount: Int? = nil) throws {
        let process = Process()
        process.executableURL = try RuntimeConfig.load().ffmpeg
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
            "aevalsrc=\(expression):s=48000:d=\(duration)"
        ]
        if let sampleCount { arguments += ["-af", "atrim=end_sample=\(sampleCount)"] }
        process.arguments = arguments + [
            "-ac", String(channels), "-c:a", "libopus", "-b:a", "96k",
            "-page_duration", "20000", "-flush_packets", "1", "-y", url.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "FFmpeg must generate a real Ogg Opus fixture")
    }
    static func checkSignal(_ samples: [Float], startFrame: Int, amplitude: Double, _ message: String) throws {
        let errors = samples.enumerated().map { index, value in
            abs(Double(value) - amplitude * sin(Double(startFrame + index) * 2 * .pi * 997 / 16000))
        }
        try check(errors.reduce(0, +) / Double(errors.count) < 0.025, message)
    }


    static func lastPageStart(_ data: Data) throws -> Int {
        var offset = 0
        var last: Int?
        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data("OggS".utf8) else { break }
            let segmentCount = Int(data[offset + 26])
            let lacingStart = offset + 27
            guard lacingStart + segmentCount <= data.count else { break }
            let payloadSize = data[lacingStart..<(lacingStart + segmentCount)].reduce(0) { $0 + Int($1) }
            let pageEnd = lacingStart + segmentCount + payloadSize
            guard pageEnd <= data.count else { break }
            last = offset
            offset = pageEnd
        }
        guard let last else {
            throw LiveTranscriptionTestFailure(message: "Ogg fixture must contain a complete page")
        }
        return last
    }

    static func testGrowingOggAudioAndMixAlignment(in directory: URL) throws {
        let micURL = directory.appendingPathComponent("microphone.ogg")
        let systemURL = directory.appendingPathComponent("system.ogg")
        try encodeOgg(micURL, expression: "0.375*sin(2*PI*997*t)", duration: "0.5")
        try encodeOgg(systemURL, expression: "0.125*sin(2*PI*997*t)", duration: "1")

        let mixer = LiveAudioMixer(directory: directory)
        try check(try mixer.availableFrameCount() == 16_000,
                  "Ogg Opus channels must be placed on the shared 16 kHz timeline")
        let firstWindow = try mixer.read(fromFrame: 4_000, toFrame: 4_800)
        let nextWindow = try mixer.read(fromFrame: 8_000, toFrame: 8_800)
        try check(firstWindow.count == 800 && nextWindow.count == 800, "Each bounded read must return only its requested samples")
        try checkSignal(firstWindow, startFrame: 4_000, amplitude: 0.25,
                        "A nonzero-offset window must average aligned microphone and system audio")
        try checkSignal(nextWindow, startFrame: 8_000, amplitude: 0.125,
                        "Samples after the microphone stops must use the system source only")
        let afterMicrophoneEnds = try mixer.read(fromFrame: 12_000, toFrame: 12_800)
        try checkSignal(afterMicrophoneEnds, startFrame: 12_000, amplitude: 0.125,
                        "A source that stopped earlier must leave the remaining source readable")
        let seekDirectory = directory.appendingPathComponent("seek", isDirectory: true)
        try FileManager.default.createDirectory(at: seekDirectory, withIntermediateDirectories: true)
        try encodeOgg(seekDirectory.appendingPathComponent("microphone.ogg"),
                      expression: "0.5*sin(2*PI*997*t)", duration: "1")
        let seekMixer = LiveAudioMixer(directory: seekDirectory)
        let atStart = try seekMixer.read(fromFrame: 0, toFrame: 8)
        let atOffset = try seekMixer.read(fromFrame: 4_000, toFrame: 4_008)
        try check(abs(atStart[0]) < 0.05 && atOffset[0] > 0.3,
                  "A nonzero-offset decode must seek to the requested audio time rather than replaying from the beginning")
        let lateDirectory = directory.appendingPathComponent("late-system", isDirectory: true)
        try FileManager.default.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
        try encodeOgg(lateDirectory.appendingPathComponent("microphone.ogg"), expression: "0.2*sin(2*PI*997*t)", duration: "1")
        let lateMixer = LiveAudioMixer(directory: lateDirectory)
        try check(try lateMixer.availableFrameCount() == 16_000,
                  "A microphone-only recording must be readable before the system channel appears")
        try encodeOgg(lateDirectory.appendingPathComponent("system.ogg"), expression: "0.1*sin(2*PI*997*t)", duration: "0.5")
        let lateSystemWindow = try lateMixer.read(fromFrame: 4_000, toFrame: 4_800)
        try checkSignal(lateSystemWindow, startFrame: 4_000, amplitude: 0.15,
                        "A system channel appearing later must align with the microphone timeline")
        let finalized = directory.appendingPathComponent("finalized.ogg")
        try encodeOgg(finalized, expression: "0.2*sin(2*PI*997*t)", duration: "1")
        let complete = try Data(contentsOf: finalized)
        let finalPageOffset = try lastPageStart(complete)


        let growthDirectory = directory.appendingPathComponent("growth", isDirectory: true)
        try FileManager.default.createDirectory(at: growthDirectory, withIntermediateDirectories: true)
        let growing = growthDirectory.appendingPathComponent("microphone.ogg")
        let growingMixer = LiveAudioMixer(directory: growthDirectory)
        try complete.prefix(finalPageOffset).write(to: growing)
        let incompleteCount = try growingMixer.availableFrameCount()
        try check(incompleteCount > 0 && incompleteCount < 16_000,
                  "A live reader must expose complete Ogg pages without publishing an incomplete final page")
        try checkSignal(try growingMixer.read(fromFrame: 4_000, toFrame: 4_800), startFrame: 4_000, amplitude: 0.2,
                        "Published audio must be decodable before the final Ogg page exists")
        let appendHandle = try FileHandle(forWritingTo: growing)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: complete.dropFirst(finalPageOffset))
        try appendHandle.close()
        try check(try growingMixer.availableFrameCount() == 16_000,
                  "A growing source must expose newly finalized Ogg pages on the next poll")
        let finalizedTail = try growingMixer.read(fromFrame: 15_200, toFrame: 16_000)
        try check(finalizedTail.count == 800, "The finalized tail must include every remaining sample")
        try checkSignal(finalizedTail, startFrame: 15_200, amplitude: 0.2,
                        "The final samples become decodable after the Ogg stream is finalized")

        let truncated = directory.appendingPathComponent("truncated.ogg")
        try complete.dropLast().write(to: truncated)
        try check(try AudioFile.frameCount(at: truncated) < AudioFile.frameCount(at: finalized),
                  "A truncated final Ogg page must not contribute its granule duration")
        var corrupted = complete
        let pageStart = try lastPageStart(corrupted)
        guard corrupted.count >= pageStart + 26 else {
            throw LiveTranscriptionTestFailure(message: "Final Ogg page must contain its checksum")
        }
        corrupted[pageStart + 22] ^= 0xff
        let corruptURL = directory.appendingPathComponent("corrupt.ogg")
        try corrupted.write(to: corruptURL)
        try check(try AudioFile.frameCount(at: corruptURL) < AudioFile.frameCount(at: finalized),
                  "A CRC-invalid final page must leave earlier published pages recoverable")
        try check(try AudioFile.frameCount(at: finalized) == 48_000,
                  "A finalized one-second Opus fixture must report exact 48 kHz frames after pre-skip")
        print("PASS: Bounded Ogg reads seek accurately, mix aligned channels, and recover growing/interrupted pages")
    }
    static func testPartialSampleStopBoundaries(in directory: URL) throws {
        for sourceFrames in [48_001, 48_002, 50_176] {
            let recording = directory.appendingPathComponent("stop-\(sourceFrames)")
            try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
            let audio = recording.appendingPathComponent("microphone.ogg")
            try encodeOgg(audio, expression: "0.2*sin(2*PI*997*t)", duration: "2", sampleCount: sourceFrames)
            try check(try AudioFile.frameCount(at: audio) == Int64(sourceFrames),
                      "The stop fixture must retain its exact source sample count")
            let mixer = LiveAudioMixer(directory: recording)
            let end = try mixer.availableFrameCount()
            let start = end - 800
            let tail = try mixer.read(fromFrame: start, toFrame: end)
            try check(tail.count == 800, "An arbitrary stop boundary must leave the full final window readable")
            try checkSignal(tail, startFrame: Int(start), amplitude: 0.2,
                            "The final audio window must preserve its signal without restarting transcription")
        }
        print("PASS: Partial-sample stop boundaries preserve readable final audio without false decode failures")
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
                  "Segment end times must clamp to the true Ogg recording duration")

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
        try testGrowingOggAudioAndMixAlignment(in: directory)
        try testPartialSampleStopBoundaries(in: directory)
        try testSegmentConfirmationAndSilence()
        try testAbsoluteSegmentMapping()
        print("All live-transcription regressions passed.")
    }
}
