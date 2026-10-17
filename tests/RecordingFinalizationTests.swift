import Foundation
import Darwin

struct FinalizationTestFailure: Error { let message: String }

@main
struct RecordingFinalizationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw FinalizationTestFailure(message: message) }
    }
    static func executable(_ url: URL, _ body: String) throws {
        try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func main() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("catet-finalization-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appendingPathComponent("meetings")
        let oldRoot = ProcessInfo.processInfo.environment["CATET_MEETINGS_ROOT"]
        setenv("CATET_MEETINGS_ROOT", root.path, 1)
        defer {
            if let oldRoot { setenv("CATET_MEETINGS_ROOT", oldRoot, 1) }
            else { unsetenv("CATET_MEETINGS_ROOT") }
        }
        let store = MeetingStore()
        try store.createRoot()
        let ffmpeg = temp.appendingPathComponent("ffmpeg")
        let whisper = temp.appendingPathComponent("whisper")
        let codex = temp.appendingPathComponent("codex")
        let calls = temp.appendingPathComponent("batch-calls")
        let fail = temp.appendingPathComponent("fail")
        // Exercise the real engine and lock handoff, substituting only codec/model tools.
        try executable(ffmpeg, """
        printf 'attempt\\n' >> '\(calls.path)'
        input=''
        while [ "$#" -gt 1 ]; do
          if [ "$1" = '-i' ]; then shift; input="$1"; fi
          shift
        done
        /bin/cp "$input" "$1"
        """)
        try executable(whisper, """
        if [ -f '\(fail.path)' ]; then printf 'decoder failed\\n' >&2; exit 7; fi
        while [ "$1" != '-of' ]; do shift; done
        shift
        printf '%s' '{"transcription":[{"offsets":{"from":0,"to":2000},"text":"Recovered from the complete saved recording."}]}' > "$1.json"
        """)
        try executable(codex, "exit 99")
        let runtime = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("runtime.json")
        try JSONSerialization.data(withJSONObject: ["ffmpeg": ffmpeg.path, "whisper": whisper.path,
            "model": temp.appendingPathComponent("model").path, "vad": temp.appendingPathComponent("vad").path,
            "codex": codex.path]).write(to: runtime)
        defer { try? fm.removeItem(at: runtime) }
        try JSONSerialization.data(withJSONObject: ["command": ["/usr/bin/true"]])
            .write(to: temp.appendingPathComponent("hooks.json"))
        let audio = Data(repeating: 31, count: 128)
        func recording(_ title: String) throws -> Meeting {
            let meeting = try store.newMeeting(title: title, generateMoM: true)
            try audio.write(to: meeting.directory.appendingPathComponent("microphone.wav"))
            try store.reserveForLiveTranscription(meeting.id)
            try store.update(id: meeting.id) { $0.status = "transcribing" }
            return meeting
        }
        let recovered = try recording("Recover failed live transcription")
        // An incomplete live publication must not cause the batch engine to skip audio.
        try "partial live output".write(to: recovered.directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try Data(#"{"segments":[{"start":0,"end":1,"text":"partial live output"}]}"#.utf8)
            .write(to: recovered.directory.appendingPathComponent("transcript.json"))
        var stayedInProgress = false
        try await store.finishTranscription(meeting: recovered, finishLive: {
            throw FinalizationTestFailure(message: "Live decoder unavailable")
        }, cancelLive: {
            // Cancellation still owns the recording. Refresh must not recover it as failed.
            stayedInProgress = store.loadAndRecover().first { $0.id == recovered.id }?.status == "transcribing"
        })
        let ready = store.meeting(id: recovered.id)!
        try check(ready.status == "transcribed" && ready.error == nil && ready.generate_mom == true,
                  "Saved-audio recovery must finish the transcript without consuming the notes preference")
        try check(try String(contentsOf: recovered.directory.appendingPathComponent("transcript.txt")).contains("Recovered from the complete saved recording."),
                  "Recovery must replace partial live output with the full saved-audio transcript")
        try check(try Data(contentsOf: recovered.directory.appendingPathComponent("microphone.wav")) == audio,
                  "Recovery must preserve the original recording")
        try check(stayedInProgress, "A provisional live failure must stay in progress until handoff")
        try check(!store.isLocallyProcessing(recovered.id), "Recovery must release the recording and engine reservations")
        try check(try MeetingHooks.status(root: root).map { $0["event"] as! String } == ["transcript.ready"],
                  "Successful recovery must emit readiness without a premature processing.failed event")
        try check(try String(contentsOf: calls) == "attempt\n", "Recovery must perform one full saved-audio pass")
        print("PASS: Live failure recovers through the real engine with canonical lock handoff and no premature failure")

        let failed = try recording("Both transcribers fail")
        try Data().write(to: fail)
        do {
            try await store.finishTranscription(meeting: failed, finishLive: {
                throw FinalizationTestFailure(message: "Live decoder unavailable")
            }, cancelLive: {})
            throw FinalizationTestFailure(message: "A failed batch retry must remain a failure")
        } catch is StoreError { }
        let failure = store.meeting(id: failed.id)!
        try check(failure.status == "failed" && failure.error_kind == "transcription" && failure.failed_step == "transcribe",
                  "Only the final batch failure must expose manual transcription retry")
        try check(failure.failureMessage?.contains("Retry transcription") == true,
                  "Final failure must give an actionable manual retry")
        try check(try Data(contentsOf: failed.directory.appendingPathComponent("microphone.wav")) == audio,
                  "Final failure must keep saved audio")
        try check(!store.isLocallyProcessing(failed.id), "Final failure must release reservations")
        try check(try MeetingHooks.status(root: root).filter { $0["event"] as? String == "processing.failed" }.count == 1,
                  "Live plus batch failure must publish exactly one final failure event")
        try check(try String(contentsOf: calls) == "attempt\nattempt\n", "Automatic retry must stop after one batch failure")
        print("PASS: Failed saved-audio retry preserves audio, publishes one final failure, and leaves manual retry available")

        let live = try recording("Live transcription succeeds")
        try await store.finishTranscription(meeting: live, finishLive: {
            try "Completed live transcript".write(to: live.directory.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        }, cancelLive: { fatalError("A successful live transcription must not be cancelled") })
        try check(store.meeting(id: live.id)?.status == "transcribed" && !store.isLocallyProcessing(live.id),
                  "Successful live finalization must publish readiness and release its reservation")
        try check(try String(contentsOf: calls) == "attempt\nattempt\n", "Successful live transcription must not trigger batch processing")
        print("PASS: Successful live finalization avoids unnecessary batch transcription")
    }
}
