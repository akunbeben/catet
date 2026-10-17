import Foundation
import Darwin

struct HookTestFailure: Error { let message: String }

@main struct HookRegressionTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw HookTestFailure(message: message) }
    }

    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }
        throw HookTestFailure(message: message)
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--deliver" {
            do { try MeetingHooks.deliverPending(root: URL(fileURLWithPath: args[2])); return }
            catch { fputs("hook worker: \(error.localizedDescription)\n", stderr); Darwin.exit(3) }
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("catet-hook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try testDisabledAndPayload(root: temporary.appendingPathComponent("disabled/meetings"))
        try testConfigValidation(root: temporary.appendingPathComponent("invalid/meetings"))
        try testFailureAndRetry(root: temporary.appendingPathComponent("retry/meetings"))
        try testPressureAndClosedStdin(root: temporary.appendingPathComponent("pressure/meetings"))
        try testTimeout(root: temporary.appendingPathComponent("timeout/meetings"))
        try testRootIsolation(parent: temporary.appendingPathComponent("shared-parent"))
        try testCrossProcessExclusionAndRecovery(root: temporary.appendingPathComponent("crash/meetings"))
        print("PASS: Durable hook events, safe command execution, retries, and crash recovery")
    }

    private static func makeMeeting(_ root: URL, id: String = "meeting-1") throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["id": id, "title": "A private meeting", "status": "complete"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("meeting.json"))
        try Data("private transcript content must not be in the event".utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        try Data("private notes content must not be in the event".utf8).write(to: directory.appendingPathComponent("mom.md"))
        return directory
    }

    private static func configure(_ root: URL, command: [String], events: [String]? = nil) throws {
        let configURL = root.deletingLastPathComponent().appendingPathComponent("hooks.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config: [String: Any] = ["command": command]
        if let events { config["events"] = events }
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
    }

    private static func script(_ url: URL, _ body: String) throws {
        try Data(("#!/bin/sh\nset -eu\n" + body + "\n").utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else { throw HookTestFailure(message: "Could not make a test command executable") }
    }

    private static func entries(_ root: URL) throws -> [[String: Any]] {
        try MeetingHooks.status(root: root)
    }

    private static func testDisabledAndPayload(root: URL) throws {
        let directory = try makeMeeting(root)
        try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:])
        try check(try entries(root).isEmpty, "Absent configuration must disable hook creation")
        try MeetingHooks.deliverPending(root: root)

        let receiver = root.deletingLastPathComponent().appendingPathComponent("receiver.sh")
        let payloadURL = root.deletingLastPathComponent().appendingPathComponent("received.json")
        let environmentURL = root.deletingLastPathComponent().appendingPathComponent("received.env")
        try script(receiver, "env > \"$1\"\ncat > \"$2\"")
        try configure(root, command: [receiver.path, environmentURL.path, payloadURL.path], events: ["recording.saved"])
        let oldAPI = getenv("OPENAI_API_KEY").map { String(cString: $0) }
        let oldCodex = getenv("CODEX_ACCESS_TOKEN").map { String(cString: $0) }
        let oldGitHub = getenv("GITHUB_TOKEN").map { String(cString: $0) }
        let oldAWS = getenv("AWS_ACCESS_KEY_ID").map { String(cString: $0) }
        setenv("OPENAI_API_KEY", "test-openai-secret", 1)
        setenv("CODEX_ACCESS_TOKEN", "test-codex-secret", 1)
        setenv("GITHUB_TOKEN", "test-github-secret", 1)
        setenv("AWS_ACCESS_KEY_ID", "test-aws-secret", 1)
        defer {
            restoreEnvironment("OPENAI_API_KEY", oldAPI); restoreEnvironment("CODEX_ACCESS_TOKEN", oldCodex)
            restoreEnvironment("GITHUB_TOKEN", oldGitHub); restoreEnvironment("AWS_ACCESS_KEY_ID", oldAWS)
        }
        try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:])
        try MeetingHooks.deliverPending(root: root)
        let data = try Data(contentsOf: payloadURL)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(payload["schema_version"] as? Int == 1, "Hook payload must have schema version one")
        try check(payload["event"] as? String == "recording.saved", "Hook payload must retain the event name")
        let meeting = payload["meeting"] as! [String: Any]
        try check(meeting["id"] as? String == "meeting-1" && meeting["title"] as? String == "A private meeting", "Payload meeting fields must be snapshotted")
        let files = payload["files"] as! [String: Any]
        try check(files["metadata"] as? String == directory.appendingPathComponent("meeting.json").path, "Payload must provide the safe metadata file path")
        try check(files["transcript_text"] as? String == directory.appendingPathComponent("transcript.txt").path, "Payload may expose finalized output paths")
        let serialized = String(decoding: data, as: UTF8.self)
        try check(!serialized.contains("private transcript content") && !serialized.contains("private notes content"), "Payload must not contain transcript or notes content")
        let environment = try String(contentsOf: environmentURL, encoding: .utf8)
        try check(environment.contains("PATH=") && environment.contains("HOME="), "Hook environment must preserve PATH and HOME")
        try check(!environment.contains("test-openai-secret") && !environment.contains("test-codex-secret") && !environment.contains("test-github-secret") && !environment.contains("test-aws-secret"), "Hook environment must strip credential values")
        let statuses = try entries(root)
        try check(statuses.count == 1 && statuses[0]["status"] as? String == "delivered" && (statuses[0]["attempts"] as? Int) == 1, "Delivered status must be persisted")
        print("PASS: Disabled-by-default hooks, immutable JSON stdin payload, and secret-safe environment")
    }

    private static func testConfigValidation(root: URL) throws {
        let directory = try makeMeeting(root)
        try configure(root, command: ["relative-hook"])
        try rejects({ try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:]) }, "Relative executables must be rejected")
        try configure(root, command: ["/bin/true"], events: ["unknown.event"])
        try rejects({ try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:]) }, "Unknown configured event names must be rejected")
        try rejects({ try MeetingHooks.enqueue(event: "unknown.event", directory: directory, metadata: [:]) }, "Unknown event names must be rejected")
        try rejects({ _ = try entries(root) }, "Invalid configuration must be surfaced by the read-only status API")
        print("PASS: Malformed hook configuration is rejected without queueing")
    }

    private static func testFailureAndRetry(root: URL) throws {
        let directory = try makeMeeting(root)
        let command = root.deletingLastPathComponent().appendingPathComponent("retry.sh")
        let count = root.deletingLastPathComponent().appendingPathComponent("attempt-count")
        let payloadURL = root.deletingLastPathComponent().appendingPathComponent("retry-payload.json")
        try script(command, "n=0\nif [ -f \"$1\" ]; then n=$(cat \"$1\"); fi\nn=$((n + 1))\nprintf '%s' \"$n\" > \"$1\"\nprintf 'safe diagnostic marker\\n' >&2\nif [ \"$n\" -eq 1 ]; then exit 7; fi\ncat > \"$2\"")
        try configure(root, command: [command.path, count.path, payloadURL.path], events: ["processing.failed"])
        try MeetingHooks.enqueue(event: "processing.failed", directory: directory,
                                metadata: ["failure": ["kind": "transcription", "step": "transcription", "retry_at": "2026-10-18T12:00:00Z", "message": "RAW_DIAGNOSTIC_SECRET"]])
        let id = try XCTOnlyFirst(entries(root))["id"] as! String
        try rejects({ try MeetingHooks.deliverPending(root: root) }, "Nonzero hook exit must be reported")
        var current = try XCTOnlyFirst(entries(root))
        try check(current["status"] as? String == "failed" && current["attempts"] as? Int == 1, "Nonzero exit must persist failed state and attempt count")
        let diagnosticPath = current["diagnostic_path"] as! String
        let diagnostic = try String(contentsOfFile: diagnosticPath, encoding: .utf8)
        try check(diagnostic.contains("safe diagnostic marker"), "Failed command stderr must be retained in a diagnostic file")
        try check(!(current["error"] as? String ?? "").contains("safe diagnostic marker"), "Raw command diagnostics must not enter status errors")
        try MeetingHooks.deliverPending(root: root)
        try check((try XCTOnlyFirst(entries(root)))["attempts"] as? Int == 1, "Failed commands must not be automatically retried")
        try MeetingHooks.retryFailed(root: root)
        current = try XCTOnlyFirst(entries(root))
        try check(current["id"] as? String == id && current["status"] as? String == "delivered" && current["attempts"] as? Int == 2, "Manual retry must preserve event ID and increment attempts")
        try check(!(current["error"] as? String ?? "").isEmpty && (current["errors"] as? [String])?.count == 1, "Successful retry must retain the earlier error")
        let payload = try String(contentsOf: payloadURL, encoding: .utf8)
        try check(!payload.contains("RAW_DIAGNOSTIC_SECRET") && payload.contains("The recording could not be transcribed"), "Failure payload must use a sanitized message, not raw diagnostics")
        print("PASS: Failed-command diagnostics, explicit same-ID retry, and failure redaction")
    }

    private static func testPressureAndClosedStdin(root: URL) throws {
        let directory = try makeMeeting(root)
        let command = root.deletingLastPathComponent().appendingPathComponent("pressure.sh")
        try script(command, "exec 0<&-\n/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\000' x\n/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\000' y >&2\nexit 0")
        try configure(root, command: [command.path], events: ["recording.saved"])
        try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:])
        try MeetingHooks.deliverPending(root: root, timeout: 8)
        let current = try XCTOnlyFirst(entries(root))
        try check(current["status"] as? String == "delivered", "Large stdout and stderr plus early stdin close must not deadlock or trigger SIGPIPE")
        try check(current["attempts"] as? Int == 1, "Pressure delivery must run once")
        print("PASS: High-volume stdout/stderr drain and closed stdin safety")
    }

    private static func testTimeout(root: URL) throws {
        let directory = try makeMeeting(root)
        let command = root.deletingLastPathComponent().appendingPathComponent("timeout.sh")
        try script(command, "printf 'before timeout\\n' >&2\nsleep 20")
        try configure(root, command: [command.path], events: ["recording.saved"])
        try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:])
        let start = Date()
        try rejects({ try MeetingHooks.deliverPending(root: root, timeout: 1) }, "Timed-out hook command must fail")
        let current = try XCTOnlyFirst(entries(root))
        try check(current["status"] as? String == "failed" && current["attempts"] as? Int == 1, "Timeout must persist failed state")
        try check(Date().timeIntervalSince(start) < 5, "Timeout must terminate the command process group promptly")
        let diagnostic = try String(contentsOfFile: current["diagnostic_path"] as! String, encoding: .utf8)
        try check(diagnostic.contains("before timeout"), "Timeout diagnostics must be retained")
        print("PASS: Bounded timeout and diagnostic retention")
    }

    private static func testCrossProcessExclusionAndRecovery(root: URL) throws {
        let directory = try makeMeeting(root)
        let command = root.deletingLastPathComponent().appendingPathComponent("crash-command.sh")
        let count = root.deletingLastPathComponent().appendingPathComponent("crash-count")
        let marker = root.deletingLastPathComponent().appendingPathComponent("command-started")
        let processIDFile = root.deletingLastPathComponent().appendingPathComponent("hook-pid")
        let payloadURL = root.deletingLastPathComponent().appendingPathComponent("recovered-payload.json")
        try script(command, "n=0\nif [ -f \"$1\" ]; then n=$(cat \"$1\"); fi\nn=$((n + 1))\nprintf '%s' \"$n\" > \"$1\"\nif [ \"$n\" -eq 1 ]; then printf '%s' \"$$\" > \"$3\"; : > \"$2\"; sleep 30; else cat > \"$4\"; fi")
        try configure(root, command: [command.path, count.path, marker.path, processIDFile.path, payloadURL.path], events: ["recording.saved"])
        try MeetingHooks.enqueue(event: "recording.saved", directory: directory, metadata: [:])
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = ["--deliver", root.path]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try check(FileManager.default.fileExists(atPath: marker.path), "Child worker must begin delivery")
        let id = try XCTOnlyFirst(entries(root))["id"] as! String
        try MeetingHooks.deliverPending(root: root) // Busy worker is a nonblocking no-op.
        let countBeforeCrash = try String(contentsOf: count, encoding: .utf8)
        try check(countBeforeCrash == "1", "A second process must not deliver while the worker lock is held")
        let childPID = pid_t(try String(contentsOf: processIDFile, encoding: .utf8))!
        _ = kill(worker.processIdentifier, SIGKILL)
        worker.waitUntilExit()
        _ = kill(-childPID, SIGKILL)
        try MeetingHooks.deliverPending(root: root)
        let current = try XCTOnlyFirst(entries(root))
        try check(current["status"] as? String == "delivered" && current["id"] as? String == id && current["attempts"] as? Int == 2, "Interrupted delivery must recover with the same ID and a new attempt")
        try check((current["errors"] as? [String])?.contains(where: { $0.contains("interrupted") }) == true, "Crash recovery must retain an actionable interruption error")
        try check(FileManager.default.fileExists(atPath: payloadURL.path), "Recovered delivery must receive the queued JSON payload")
        print("PASS: Cross-process exclusion and interrupted-delivery recovery")
    }

    private static func testRootIsolation(parent: URL) throws {
        let firstRoot = parent.appendingPathComponent("meetings-first")
        let secondRoot = parent.appendingPathComponent("meetings-second")
        let firstDirectory = try makeMeeting(firstRoot, id: "first")
        let secondDirectory = try makeMeeting(secondRoot, id: "second")
        let command = parent.appendingPathComponent("root-isolation.sh")
        try script(command, "cat > /dev/null")
        try configure(firstRoot, command: [command.path], events: ["recording.saved"])
        try MeetingHooks.enqueue(event: "recording.saved", directory: firstDirectory, metadata: [:])
        try MeetingHooks.enqueue(event: "recording.saved", directory: secondDirectory, metadata: [:])
        let firstQueued = try entries(firstRoot)
        let secondQueued = try entries(secondRoot)
        try check(firstQueued.count == 1 && secondQueued.count == 1, "Sibling meeting roots must have separate hook journals")
        try MeetingHooks.deliverPending(root: firstRoot)
        try check(try XCTOnlyFirst(entries(firstRoot))["status"] as? String == "delivered", "First root should deliver its own event")
        try check(try XCTOnlyFirst(entries(secondRoot))["status"] as? String == "pending", "First root worker must not drain a sibling root")
        try MeetingHooks.deliverPending(root: secondRoot)
        try check(try XCTOnlyFirst(entries(secondRoot))["status"] as? String == "delivered", "Sibling root should drain only when requested")
        print("PASS: Same-parent meeting roots remain isolated")
    }

    private static func XCTOnlyFirst(_ entries: [[String: Any]]) throws -> [String: Any] {
        guard let entry = entries.first else { throw HookTestFailure(message: "Expected one hook status entry") }
        return entry
    }

    private static func restoreEnvironment(_ key: String, _ value: String?) {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
}
