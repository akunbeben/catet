import Foundation
import AppKit
import AVFoundation
import Darwin
import ScreenCaptureKit

struct AudioTestFailure: Error { let message: String }

@main
struct AudioRegressionTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AudioTestFailure(message: message) }
    }
    static func buffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for frame in 0..<160 {
            let sample = Float(sin(Double(frame) * 2 * .pi * 400 / 16000))
            buffer.floatChannelData![0][frame] = 0.5 * sample
            buffer.floatChannelData![1][frame] = -0.25 * sample
        }
        return buffer
    }
    static func decodedMono(_ input: URL, root: URL) throws -> [Float] {
        let output = root.appendingPathComponent("decoded-\(UUID().uuidString).f32")
        let process = Process()
        process.executableURL = try RuntimeConfig.load().ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                             "-f", "f32le", "-ac", "1", "-ar", "32000", output.path]
        try process.run()
        process.waitUntilExit()
        try check(process.terminationStatus == 0, "Ogg Opus output must decode successfully")
        let data = try Data(contentsOf: output)
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
    static func childSeesMeetingLock(root: URL, meetingID: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--check-meeting-lock", root.path, meetingID]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    static func testLiveTranscriptionReservationLifecycle(using store: MeetingStore) throws {
        let observer = MeetingStore()
        let meeting = try store.newMeeting(title: "Live transcription reservation")
        try store.reserveForLiveTranscription(meeting.id)
        try check(observer.loadAndRecover().first { $0.id == meeting.id }?.status == "recording",
                  "A second store must not recover an active recording")
        try check(observer.isProcessRunning(for: meeting),
                  "Live transcription must hold the canonical meeting lock seen by other processes")
        let lockVisibleInChild = try childSeesMeetingLock(root: store.root, meetingID: meeting.id)
        try check(lockVisibleInChild, "A separate process must see the canonical meeting lock")
        var secondReservationBlocked = false
        do {
            try observer.reserveForLiveTranscription(meeting.id)
        } catch is StoreError { secondReservationBlocked = true }
        try check(secondReservationBlocked, "A second store must not reserve the same meeting")

        try store.update(id: meeting.id) { $0.status = "transcribing" }
        try check(observer.loadAndRecover().first { $0.id == meeting.id }?.status == "transcribing",
                  "A second store must not recover an active transcription finalization")

        try store.update(id: meeting.id) { $0.status = "transcribed" }
        var engineBlocked = false
        observer.runEngine(meeting: meeting, command: "process", transcriptOnly: true) {
            if case .failure = $0 { engineBlocked = true }
        }
        try check(engineBlocked, "Another store must not start a duplicate engine worker during finalization")
        try check(observer.isLocallyProcessing(meeting.id), "The reservation must be visible to another store instance")
        var trashBlocked = false
        do {
            try observer.moveToTrash(ids: [meeting.id])
        } catch is StoreError { trashBlocked = true }
        try check(trashBlocked && FileManager.default.fileExists(atPath: meeting.directory.path),
                  "Another store must not trash a reserved meeting even after its metadata changes")

        store.releaseLiveTranscriptionReservation(meeting.id)
        try check(!observer.isLocallyProcessing(meeting.id), "Releasing the reservation must release the cross-store lock")
        try store.update(id: meeting.id) { $0.status = "transcribing" }
        let lockReleasedInChild = try !childSeesMeetingLock(root: store.root, meetingID: meeting.id)
        try check(lockReleasedInChild, "A separate process must see the canonical lock released after finalization")
        let recovered = observer.loadAndRecover().first { $0.id == meeting.id }
        try check(recovered?.status == "failed" && recovered?.failed_step == "transcribe"
                  && recovered?.failureMessage?.contains("try again") == true,
                  "After release, interrupted finalization must recover to an actionable retry state")
        let completed = try store.newMeeting(title: "Live transcription completed")
        try store.reserveForLiveTranscription(completed.id)
        try store.update(id: completed.id) { $0.status = "transcribing" }
        try store.update(id: completed.id) { $0.status = "transcribed"; $0.error = nil; $0.error_kind = nil }
        store.releaseLiveTranscriptionReservation(completed.id)
        try check(observer.meeting(id: completed.id)?.statusLabel == "Transcript ready",
                  "Successful live finalization must leave a transcript-ready state")

        let failed = try store.newMeeting(title: "Live transcription failed")
        try store.reserveForLiveTranscription(failed.id)
        try store.update(id: failed.id) { $0.status = "transcribing" }
        try store.update(id: failed.id) {
            $0.status = "failed"; $0.error = "Model unavailable"; $0.error_kind = "transcription"
        }
        store.releaseLiveTranscriptionReservation(failed.id)
        let failedMeeting = observer.meeting(id: failed.id)
        try check(failedMeeting?.status == "failed"
                  && failedMeeting?.failureMessage?.contains("Retry transcription") == true,
                  "Live transcription failure must remain failed and offer an actionable retry")
        print("PASS: Live transcription reservations block recovery, duplicate workers and trash until finalization")
    }

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--check-meeting-lock" {
            setenv("CATET_MEETINGS_ROOT", CommandLine.arguments[2], 1)
            let store = MeetingStore()
            guard let meeting = store.meeting(id: CommandLine.arguments[3]) else { _exit(2) }
            _exit(store.isProcessRunning(for: meeting) ? 0 : 1)
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--encoder-failure" {
            do {
                let input = buffer()
                let writer = try AudioWriter(url: URL(fileURLWithPath: CommandLine.arguments[2]), source: input.format)
                for _ in 0..<100 { try writer.append(input) }
                try writer.finish()
                _exit(3)
            } catch is AudioError { _exit(0) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-and-crash" {
            let input = buffer()
            let writer = try AudioWriter(url: URL(fileURLWithPath: CommandLine.arguments[2]), source: input.format)
            for _ in 0..<100 { try writer.append(input) }
            _exit(0) // The inherited stdin close must make ffmpeg finalize its Ogg stream.
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catet-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, body) in [
            ("exits-before-input", "exit 7"),
            ("fails-on-finalize", "/bin/cat >/dev/null\\nexit 7")
        ] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("audio-tests")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
            let encoder = directory.appendingPathComponent("encoder")
            try ("#!/bin/sh\n" + body.replacingOccurrences(of: "\\n", with: "\n") + "\n")
                .write(to: encoder, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: encoder.path)
            let config = ["ffmpeg": encoder.path, "whisper": "/unused", "model": "/unused",
                          "vad": "/unused", "codex": "/unused"]
            try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("runtime.json"))
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--encoder-failure", directory.appendingPathComponent("microphone.ogg").path]
            try child.run()
            child.waitUntilExit()
            try check(child.terminationReason == .exit && child.terminationStatus == 0,
                      "Encoder termination and finalization failures must surface as errors without a SIGPIPE crash")
        }
        print("PASS: Encoder termination and finalization failures remain truthful and SIGPIPE-safe")

        for channels: AVAudioChannelCount in [1, 2, 4, 6] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                       interleaved: false, channelLayout: layout)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            input.frameLength = 480
            for channel in 0..<Int(channels) {
                for frame in 0..<480 {
                    input.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 400 / 48000)) * 0.1
                }
            }
            let path = root.appendingPathComponent("channels-\(channels).ogg")
            let writer = try AudioWriter(url: path, source: format)
            try writer.append(input)
            try writer.finish()
            try check(try AudioFile.frameCount(at: path) == 480, "Opus output must preserve the exact multichannel recording duration")
            let samples = try decodedMono(path, root: root)
            let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
            try check(energy > 0.001 && energy < 0.03, "Multichannel capture must retain the recorded signal after Opus downmix")
        }
        print("PASS: Mono, stereo and multichannel inputs encode to mono Opus")

        let path = root.appendingPathComponent("microphone.ogg")
        let source = buffer()
        let writer = try AudioWriter(url: path, source: source.format)
        try writer.pad(to: 16_000)
        for _ in 0..<100 { try writer.append(source) }
        try check(try AudioFile.frameCount(at: path) > 0, "Complete Ogg pages must be readable before finish")
        for _ in 0..<100 { try writer.append(source) }
        try writer.append(source, skipping: 80)
        try writer.finish()
        let duration = try AudioFile.duration(at: path)
        try check(abs(duration - 3.005) < 0.08, "Silence padding and overlap trimming must preserve the recording timeline")
        let samples = try decodedMono(path, root: root)
        try check(samples.prefix(1000).allSatisfy { abs($0) < 0.03 }, "Timestamp gaps must decode as silence")
        try check(samples.dropFirst(8000).contains { $0 > 0.1 }, "Captured microphone audio must survive Opus encoding")
        print("PASS: Early Ogg pages, silence padding, overlap trimming and lossy audio")

        let crashed = root.appendingPathComponent("interrupted.ogg")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--write-and-crash", crashed.path]
        try child.run()
        child.waitUntilExit()
        try check(child.terminationStatus == 0, "Crash fixture writer must complete its append")
        var recoveredFrames: Int64 = 0
        let recoveryDeadline = Date().addingTimeInterval(5)
        while Date() < recoveryDeadline {
            recoveredFrames = (try? AudioFile.frameCount(at: crashed)) ?? 0
            if recoveredFrames == 48_000 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try check(abs(Double(recoveredFrames) / 48_000 - 1) < 0.08, "Encoder must finalize all already-written audio after parent exit")
        print("PASS: Interrupted recording retains finalized Opus pages")

        setenv("CATET_MEETINGS_ROOT", root.appendingPathComponent("meetings").path, 1)
        let store = MeetingStore()
        try store.createRoot()
        try testLiveTranscriptionReservationLifecycle(using: store)
        let meeting = try store.newMeeting(title: "Recovery")
        let metadataURL = meeting.directory.appendingPathComponent("meeting.json")
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        metadata["failed_step"] = "mom"
        metadata["integration"] = ["external_id": "ticket-42"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        try store.update(id: meeting.id) { $0.status = "failed"; $0.error = "Codex unavailable" }
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        try check((updated["integration"] as? [String: String])?["external_id"] == "ticket-42" && updated["failed_step"] as? String == "mom", "App state updates must preserve integration and retry metadata")
        print("PASS: Native app updates preserve external integration and failure metadata")
        try store.update(id: meeting.id) {
            $0.status = "waiting_for_limit"
            $0.error = "A private prompt and transcript must not appear in the interface."
            $0.error_kind = "usage_limit"
            $0.retry_at = "2030-01-01T10:00:00Z"
            $0.codex_account_id = "default"
        }
        try store.update(id: meeting.id) { $0.capture_warning = "System audio was unavailable." }
        let waiting = store.meeting(id: meeting.id)!
        try check(waiting.status == "waiting_for_limit" && waiting.retryDate != nil && waiting.codex_account_id == "default", "Capture metadata updates must preserve durable notes recovery")
        try check(waiting.failureMessage?.contains("private prompt") == false, "Failure presentation must never expose stored prompts or transcripts")
        try store.update(id: meeting.id) {
            $0.status = "failed"; $0.error_kind = nil; $0.retry_at = nil
            $0.error = "OpenAI Codex session metadata\\nPRIVATE TRANSCRIPT\\nERROR: You’ve hit your usage limit."
        }
        let legacyFailure = store.meeting(id: meeting.id)!
        try check(legacyFailure.isUsageLimited && legacyFailure.failureMessage?.contains("PRIVATE TRANSCRIPT") == false, "Legacy Codex failures must be recognized without exposing diagnostic content")
        try check(legacyFailure.retryDate == nil, "Unknown legacy reset times must not invent automatic retries")
        print("PASS: Durable notes recovery survives metadata updates and legacy errors remain private")
        let denied = CaptureIssue(source: .systemAudio, error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        let invalidConfig = CaptureIssue(source: .systemAudio, error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.invalidParameter.rawValue))
        let unrelated = CaptureIssue(source: .systemAudio, error: NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        try check(denied.permissionDenied && !invalidConfig.permissionDenied && !unrelated.permissionDenied, "Only ScreenCaptureKit authorization denial should be treated as a permission failure")
        try store.update(id: meeting.id) { $0.capture_warning = denied.warning }
        try store.update(id: meeting.id) { $0.status = "recorded"; $0.error = nil }
        let saved = store.meeting(id: meeting.id)!
        try check(saved.status == "recorded" && saved.error == nil && saved.capture_warning != nil, "System audio failure must leave saved microphone recording available, with a separate warning")
        try store.update(id: meeting.id) { $0.status = "failed"; $0.error = "Disk full" }
        let failedCapture = store.meeting(id: meeting.id)!
        try check(failedCapture.status == "failed" && failedCapture.error == "Disk full" && failedCapture.capture_warning != nil, "Real recording write errors must still fail and preserve the partial capture warning")
        print("PASS: Permission classification and partial capture recovery preserve truthful state")

        _ = NSApplication.shared
        try check(ShortRecordingDialog(duration: 0.2) != nil && ShortRecordingDialog(duration: 3) != nil, "Short captures through three seconds must offer a discard choice")
        try check(ShortRecordingDialog(duration: 3.001) == nil && ShortRecordingDialog(duration: 0) == nil && ShortRecordingDialog(duration: nil) == nil, "Long or unknown durations must not be marked as accidental")
        let short = try store.newMeeting(title: "Short recording fixture")
        let shortAudio = try AudioWriter(url: short.directory.appendingPathComponent("microphone.ogg"), source: source.format)
        try shortAudio.pad(to: 48_000)
        try shortAudio.finish()
        try store.update(id: short.id) { $0.status = "recorded"; $0.error = nil }
        try check(abs((store.recordingDuration(for: short) ?? 0) - 3) < 0.08, "Duration must use finalized audio frames")
        let longerChannel = try AudioWriter(url: short.directory.appendingPathComponent("system.ogg"), source: source.format)
        try longerChannel.pad(to: 64_000)
        try longerChannel.finish()
        try check(abs((store.recordingDuration(for: short) ?? 0) - 4) < 0.08, "The longer channel must prevent misclassifying a recording as short")

        let lockDirectory = root.appendingPathComponent("runtime/locks")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open(lockDirectory.appendingPathComponent("\(short.id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try check(descriptor >= 0 && catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0, "Fixture must own the recording lock")
        do {
            try store.moveToTrash(ids: [short.id], onlyUnprocessedRecordings: true)
            throw AudioTestFailure(message: "An active recording must never be discarded")
        } catch is StoreError { }
        try check(FileManager.default.fileExists(atPath: short.directory.path), "Refused discard must preserve the recording")
        _ = catetFlock(descriptor, LOCK_UN)
        close(descriptor)
        let trashed = try store.moveToTrash(ids: [short.id], onlyUnprocessedRecordings: true).first
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        try check(!FileManager.default.fileExists(atPath: short.directory.path), "Discard must remove the recording from the library")
        try check(trashed != nil && FileManager.default.fileExists(atPath: trashed!.appendingPathComponent("microphone.ogg").path), "Discard must preserve recoverable audio in Trash")
        try check(store.meeting(id: meeting.id) != nil, "Discard must leave other recordings untouched")
        print("PASS: Short-duration boundaries, channel duration, active-recording protection and recoverable discard")

        let complete = try store.newMeeting(title: "Completed meeting")
        let waitingForNotes = try store.newMeeting(title: "Waiting for notes")
        try store.update(id: complete.id) { $0.status = "complete" }
        try store.update(id: waitingForNotes.id) { $0.status = "waiting_for_limit" }
        try "Saved transcript".write(to: complete.directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try "Saved notes".write(to: complete.directory.appendingPathComponent("mom.md"), atomically: true, encoding: .utf8)
        let batchLock = open(lockDirectory.appendingPathComponent("\(waitingForNotes.id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try check(batchLock >= 0 && catetFlock(batchLock, LOCK_EX | LOCK_NB) == 0, "Fixture must own a batch member's processing lock")
        do {
            try store.moveToTrash(ids: [complete.id, waitingForNotes.id])
            throw AudioTestFailure(message: "A batch containing an active meeting must be refused")
        } catch is StoreError { }
        try check(store.meeting(id: complete.id) != nil && store.meeting(id: waitingForNotes.id) != nil, "A blocked batch must keep every selected meeting")
        _ = catetFlock(batchLock, LOCK_UN)
        close(batchLock)
        do {
            try store.moveToTrash(ids: [complete.id], onlyUnprocessedRecordings: true)
            throw AudioTestFailure(message: "Short-recording discard must reject a completed meeting")
        } catch is StoreError { }
        let batchTrash = try store.moveToTrash(ids: [complete.id, waitingForNotes.id])
        defer { for url in batchTrash { try? FileManager.default.removeItem(at: url) } }
        try check(store.meeting(id: complete.id) == nil && store.meeting(id: waitingForNotes.id) == nil, "Confirmed batch deletion must remove every selected meeting from the library")
        let completedTrash = batchTrash.first { $0.lastPathComponent == complete.id }!
        try check(try String(contentsOf: completedTrash.appendingPathComponent("transcript.txt"), encoding: .utf8) == "Saved transcript", "Trash must preserve the meeting transcript")
        try check(try String(contentsOf: completedTrash.appendingPathComponent("mom.md"), encoding: .utf8) == "Saved notes", "Trash must preserve meeting notes")
        try check(store.meeting(id: meeting.id) != nil, "Batch deletion must preserve unselected meetings")
        print("PASS: Batch deletion preserves recoverable outputs, refuses active members, and protects unselected meetings")

        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = store.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        do {
            try store.moveToTrash(ids: ["linked"])
            throw AudioTestFailure(message: "A symlink outside the library must never be trashed")
        } catch is StoreError { }
        try check(FileManager.default.fileExists(atPath: outside.path), "Refused deletion must preserve the external directory")
        print("PASS: Library deletion cannot follow symlinks outside the meeting root")
        let recoveryHook = root.appendingPathComponent("recovery-hook")
        try """
        #!/bin/sh
        cat >/dev/null
        """.write(to: recoveryHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryHook.path)
        try JSONSerialization.data(withJSONObject: [
            "command": [recoveryHook.path], "events": ["processing.failed"]
        ]).write(to: root.appendingPathComponent("hooks.json"))
        let interrupted = try store.newMeeting(title: "Interrupted recovery hook")
        try store.update(id: interrupted.id) { $0.status = "transcribing" }
        _ = store.loadAndRecover()
        _ = store.loadAndRecover()
        let recoveryEvents = try MeetingHooks.status(root: store.root).filter { $0["event"] as? String == "processing.failed" }
        try check(recoveryEvents.count == 1 && store.meeting(id: interrupted.id)?.status == "failed",
                  "Interrupted processing recovery must enqueue one failure event across repeated refreshes")
        print("All native audio regressions passed.")
    }
}
