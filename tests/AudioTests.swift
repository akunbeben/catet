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
            buffer.floatChannelData![0][frame] = 0.5
            buffer.floatChannelData![1][frame] = -0.25
        }
        return buffer
    }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-and-crash" {
            let input = buffer()
            let writer = try WaveWriter(url: URL(fileURLWithPath: CommandLine.arguments[2]), source: input.format)
            try writer.append(input)
            _exit(0) // No deinit, close, or finalization. Exercise actual crash recovery.
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catet-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("microphone.wav")
        let source = buffer()
        let writer = try WaveWriter(url: path, source: source.format)
        try writer.pad(to: 800)
        try writer.append(source)
        try writer.append(source, skipping: 80)
        // Read the live file before finish. Header must already describe real samples.
        let live = try AVAudioFile(forReading: path)
        try check(live.length == 1040, "Leading silence and overlap trimming must preserve the recording timeline")
        let output = AVAudioPCMBuffer(pcmFormat: live.processingFormat, frameCapacity: 1040)!
        try live.read(into: output)
        try check(abs(output.floatChannelData![0][0]) < 0.0001, "Timestamp gap must contain silence")
        try check(abs(output.floatChannelData![0][800] - 0.5) < 0.001, "Left microphone channel must survive PCM conversion")
        try check(abs(output.floatChannelData![1][800] + 0.25) < 0.001, "Right microphone channel must survive interleaving")
        try writer.finish()
        print("PASS: Live WAV headers, channel conversion, timeline padding and overlap trimming")

        let crashed = root.appendingPathComponent("interrupted.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--write-and-crash", crashed.path]
        try process.run(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "Crash fixture writer must complete its append")
        let recovered = try AVAudioFile(forReading: crashed)
        try check(recovered.length == 160, "Audio must remain readable after process exit without finalization")
        print("PASS: Recording remains readable after unclean process exit")

        setenv("CATET_MEETINGS_ROOT", root.appendingPathComponent("meetings").path, 1)
        let store = MeetingStore()
        try store.createRoot()
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
        try store.saveRecording(id: meeting.id, failure: nil)
        let saved = store.meeting(id: meeting.id)!
        try check(saved.status == "recorded" && saved.error == nil && saved.capture_warning != nil, "System audio failure must leave saved microphone recording available, with a separate warning")
        try store.saveRecording(id: meeting.id, failure: "Disk full")
        let failedCapture = store.meeting(id: meeting.id)!
        try check(failedCapture.status == "failed" && failedCapture.error == "Disk full" && failedCapture.capture_warning != nil, "Real recording write errors must still fail and preserve the partial capture warning")
        print("PASS: Permission classification and partial capture recovery preserve truthful state")

        _ = NSApplication.shared
        try check(ShortRecordingDialog(duration: 0.2) != nil && ShortRecordingDialog(duration: 3) != nil, "Short captures through three seconds must offer a discard choice")
        try check(ShortRecordingDialog(duration: 3.001) == nil && ShortRecordingDialog(duration: 0) == nil && ShortRecordingDialog(duration: nil) == nil, "Long or unknown durations must not be marked as accidental")
        let short = try store.newMeeting(title: "Short recording fixture")
        let shortAudio = try WaveWriter(url: short.directory.appendingPathComponent("microphone.wav"), source: source.format)
        try shortAudio.pad(to: 48_000)
        try shortAudio.finish()
        try store.saveRecording(id: short.id, failure: nil)
        try check(store.recordingDuration(for: short) == 3, "Duration must use finalized audio frames")
        let longerChannel = try WaveWriter(url: short.directory.appendingPathComponent("system.wav"), source: source.format)
        try longerChannel.pad(to: 64_000)
        try longerChannel.finish()
        try check(store.recordingDuration(for: short) == 4, "The longer channel must prevent misclassifying a recording as short")

        let lockDirectory = root.appendingPathComponent("runtime/locks")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open(lockDirectory.appendingPathComponent("\(short.id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try check(descriptor >= 0 && catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0, "Fixture must own the recording lock")
        do {
            try store.discardRecording(id: short.id)
            throw AudioTestFailure(message: "An active recording must never be discarded")
        } catch is StoreError { }
        try check(FileManager.default.fileExists(atPath: short.directory.path), "Refused discard must preserve the recording")
        _ = catetFlock(descriptor, LOCK_UN)
        close(descriptor)
        let trashed = try store.discardRecording(id: short.id)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        try check(!FileManager.default.fileExists(atPath: short.directory.path), "Discard must remove the recording from the library")
        try check(trashed != nil && FileManager.default.fileExists(atPath: trashed!.appendingPathComponent("microphone.wav").path), "Discard must preserve recoverable audio in Trash")
        try check(store.meeting(id: meeting.id) != nil, "Discard must leave other recordings untouched")
        print("PASS: Short-duration boundaries, channel duration, active-recording protection and recoverable discard")
        print("All native audio regressions passed.")
    }
}
