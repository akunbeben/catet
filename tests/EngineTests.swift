import Foundation
import Darwin
import Dispatch

struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct EngineRegressionTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw RegressionFailure(description: message) }
    }

    static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() }
        catch is EngineError { return }
        catch is EngineFailure { return }
        throw RegressionFailure(description: message)
    }

    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int,
                     timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let value = calendar.date(from: components) else {
            throw RegressionFailure(description: "Could not construct test date")
        }
        return value
    }
    static func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func makeMeeting(root: URL, status: String, speech: [MeetingSegment],
                            accountID: String? = nil, retryAt: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var metadata: [String: Any] = ["id": directory.lastPathComponent, "title": "Retry fixture", "status": status]
        if let accountID { metadata["codex_account_id"] = accountID }
        if let retryAt { metadata["retry_at"] = isoDateString(retryAt) }
        try writeMetadata(metadata, to: directory)
        try writeTranscript(speech, to: directory)
        return directory
    }

    static func setEnvironment(_ key: String, _ value: String?) {
        if let value { _ = value.withCString { setenv(key, $0, 1) } }
        else { _ = unsetenv(key) }
    }

    static func environment(_ key: String) -> String? {
        guard let value = getenv(key) else { return nil }
        return String(cString: value)
    }

    static func main() throws {
        let originalAccountID = environment("CATET_CODEX_ACCOUNT_ID")
        setEnvironment("CATET_CODEX_ACCOUNT_ID", nil)
        defer { setEnvironment("CATET_CODEX_ACCOUNT_ID", originalAccountID) }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--probe-lock" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let meeting = URL(fileURLWithPath: CommandLine.arguments[3])
            do {
                let lock = try MeetingLock(directory: meeting, root: root)
                lock.unlock()
                exit(1)
            } catch is EngineError { exit(0) }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("catet-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("meetings")
        let meeting = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try writeMetadata(["id": meeting.lastPathComponent, "status": "recorded", "custom": ["keep": true]], to: meeting)

        let parsed = try normalizeWhisper(["transcription": [
            ["offsets": ["from": 1250, "to": 2500], "text": "  Keputusan rapat. "],
            ["timestamps": ["from": "01:02:03,250", "to": "01:02:04,500"], "text": "Tindak lanjut."]
        ]])
        try require(parsed == [MeetingSegment(start: 1.25, end: 2.5, text: "Keputusan rapat."), MeetingSegment(start: 3723.25, end: 3724.5, text: "Tindak lanjut.")], "Whisper times must retain millisecond precision and hour offsets")
        try rejects({ _ = try normalizeWhisper(["transcription": []]) }, "Empty audio must not become successful transcript")
        try rejects({ _ = try normalizeWhisper(["transcription": [["offsets": ["from": 2000, "to": 1000], "text": "invalid"]]]) }, "Reversed time ranges must fail")
        try rejects({ _ = try normalizeWhisper(["transcription": [["offsets": ["from": true, "to": 1000], "text": "invalid"]]]) }, "Boolean times must fail")
        print("PASS: Whisper timestamp precision and invalid segment boundaries")

        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeReset = try date(year: 2026, month: 10, day: 16, hour: 9, minute: 45, timeZone: zone)
        let actualLimit = "ERROR: You’ve hit your usage limit... try again at 10:01 AM."
        let parsedReset = parseUsageLimitReset(actualLimit, failureDate: beforeReset, timeZone: zone)
        let sameDayReset = try date(year: 2026, month: 10, day: 16, hour: 10, minute: 1, timeZone: zone)
        try require(parsedReset == sameDayReset, "The Codex local-time reset should parse on the failure day")
        let lateFailure = try date(year: 2026, month: 10, day: 16, hour: 23, minute: 30, timeZone: zone)
        let nextDayReset = try date(year: 2026, month: 10, day: 17, hour: 10, minute: 1, timeZone: zone)
        try require(parseUsageLimitReset(actualLimit, failureDate: lateFailure, timeZone: zone) == nextDayReset,
                    "A passed time-only reset should roll to the next local day")
        let explicitDate = "ERROR: You’ve hit your usage limit. Try again at 10:01 AM on October 17, 2026."
        let explicitDateExpected = try date(year: 2026, month: 10, day: 17, hour: 10, minute: 1, timeZone: zone)
        try require(parseUsageLimitReset(explicitDate, failureDate: beforeReset, timeZone: zone) == explicitDateExpected,
                    "An explicit provider date should be respected")
        try require(parseUsageLimitReset("ERROR: You’ve hit your usage limit. Try again on October 17 at 10:01 AM.",
                                         failureDate: beforeReset, timeZone: zone) == explicitDateExpected,
                    "An explicit month/day without a year should use only the local failure year")
        let afterSameDayReset = try date(year: 2026, month: 10, day: 16, hour: 11, minute: 0, timeZone: zone)
        try require(parseUsageLimitReset("ERROR: You’ve hit your usage limit. Try again on October 16 at 10:01 AM.",
                                         failureDate: afterSameDayReset, timeZone: zone) == nil,
                    "A past explicit date must not be scheduled in the next year")
        try require(parseUsageLimitReset("ERROR: You’ve hit your usage limit. Reset time unknown.",
                                         failureDate: beforeReset, timeZone: zone) == nil,
                    "Unknown reset time must not fabricate a retry date")
        try require(parseUsageLimitReset("ERROR: You’ve hit your usage limit. Try again on February 30, 2026 at 10:01 AM.",
                                         failureDate: beforeReset, timeZone: zone) == nil,
                    "Invalid explicit dates must not become scheduled retries")
        try require(parseUsageLimitReset("ERROR: You’ve hit your usage limit. Try again next Tuesday at 10:01 AM.",
                                         failureDate: beforeReset, timeZone: zone) == nil,
                    "Unrecognized textual dates must not be mistaken for a same-day reset")
        print("PASS: Codex usage reset parsing uses local time and rejects unknown or invalid dates")

        _ = try updateStatus(in: meeting, status: "failed", values: ["error": "interrupted", "failed_step": "mom"])
        let metadata = try readMetadata(from: meeting)
        try require((metadata["custom"] as? [String: Bool])?["keep"] == true, "State transitions must preserve capture metadata")
        print("PASS: Metadata survives atomic status transitions")

        let lock = try MeetingLock(directory: meeting, root: root)
        let probe = try runCommand(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, arguments: ["--probe-lock", root.path, meeting.path], timeout: 10)
        try require(probe.status == 0, "Second process must not acquire active meeting lock")
        lock.unlock()
        try Data("999999999\n".utf8).write(to: lock.path)
        let recovered = try MeetingLock(directory: meeting, root: root)
        recovered.unlock()
        print("PASS: Cross-process exclusion and stale owner recovery")

        let speech = [MeetingSegment(start: 0, end: 1.5, text: "Benny menyiapkan rilis Jumat.")]
        try writeTranscript(speech, to: meeting)
        let missing = URL(fileURLWithPath: "/catet-regression-nonexistent-executable")
        let config = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: missing)
        try rejects({ _ = try processMeeting(meeting, root: root, withMom: true, config: config) }, "Missing Codex must fail instead of pretending MoM was generated")
        let failed = try readMetadata(from: meeting)
        try require(failed["status"] as? String == "failed" && failed["failed_step"] as? String == "mom", "MoM failure must identify recoverable step")
        try require(failed["error_kind"] as? String == "codex" &&
                    (failed["error"] as? String)?.contains("could not be started") == true,
                    "Codex startup failures must be reported in concise, human-readable terms")
        try require(try readTranscript(from: meeting).0 == speech, "MoM failure must preserve transcript")
        try require(!FileManager.default.fileExists(atPath: meeting.appendingPathComponent("mom.md").path), "Failed MoM must not leave fabricated output")
        _ = try processMeeting(meeting, root: root, withMom: false, config: config)
        let resumed = try readMetadata(from: meeting)
        try require(resumed["status"] as? String == "transcribed", "Local processing must reuse transcript without Codex or retranscription")
        try require(resumed["error"] is NSNull, "Successful recovery must clear stale failure")
        try require(resumed["error_kind"] is NSNull && resumed["retry_at"] is NSNull,
                    "Manual local recovery must clear stale failure classification and retry time")
        print("PASS: Failed MoM preserves transcript and local-only recovery avoids all AI commands")

        let response = temp.appendingPathComponent("response.json")
        let codex = temp.appendingPathComponent("codex-fixture")
        let fixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Logged in using ChatGPT'
          exit 0
        fi
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "--output-last-message" ]]; then
            cp '\(response.path)' "$2"
            exit 0
          fi
          shift
        done
        exit 1
        """
        try fixture.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let generatedConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: codex)
        let expectedMinutes = "# Persiapan Rilis Jumat\n\nBenny menyiapkan rilis Jumat."
        try JSONSerialization.data(withJSONObject: ["title": "Persiapan Rilis Jumat", "mom": expectedMinutes]).write(to: response)
        let generated = try processMeeting(meeting, root: root, withMom: true, config: generatedConfig)
        let completed = try readMetadata(from: meeting)
        try require(generated == expectedMinutes && completed["title"] as? String == "Persiapan Rilis Jumat" && completed["status"] as? String == "complete", "Successful MoM must publish the contextual title and completed status")
        try require((completed["custom"] as? [String: Bool])?["keep"] == true, "Renaming must preserve integration metadata")
        let savedMinutes = try Data(contentsOf: meeting.appendingPathComponent("mom.md"))
        try require(String(data: savedMinutes, encoding: .utf8) == expectedMinutes + "\n", "MoM file must remain plain Markdown, not the structured response")
        for invalid in [
            Data("not JSON".utf8),
            try JSONSerialization.data(withJSONObject: ["title": " \n ", "mom": "Replacement"]),
            try JSONSerialization.data(withJSONObject: ["title": "Invalid\nTitle", "mom": "Replacement"]),
            try JSONSerialization.data(withJSONObject: ["title": "Replacement", "mom": " "])
        ] {
            try invalid.write(to: response)
            try rejects({ _ = try explicitMom(meeting, root: root, config: generatedConfig) }, "Invalid generated output must fail without replacing existing results")
            let unchanged = try readMetadata(from: meeting)
            try require(unchanged["title"] as? String == "Persiapan Rilis Jumat" && unchanged["status"] as? String == "failed", "Invalid regeneration must preserve the old title and report failure")
            try require(try Data(contentsOf: meeting.appendingPathComponent("mom.md")) == savedMinutes, "Invalid regeneration must preserve the previous MoM")
            try require(try readTranscript(from: meeting).0 == speech, "Renaming must never alter the transcript")
        }
        let accounts = CodexAccounts(root: root)
        let alpha = try accounts.add(label: "Alpha")
        let beta = try accounts.add(label: "Beta")
        try accounts.setAuthenticated(true, for: alpha.account.id)
        try accounts.setAuthenticated(true, for: beta.account.id)
        let alphaSnapshot = try accounts.snapshot(id: alpha.account.id)
        let betaSnapshot = try accounts.snapshot(id: beta.account.id)
        let defaultSnapshot = try accounts.snapshot(id: "default")
        let cleanAlpha = codexAccountEnvironment(base: [
            "CODEX_HOME": "/terminal/home", "OPENAI_API_KEY": "openai-secret",
            "CODEX_API_KEY": "codex-secret", "CODEX_ACCESS_TOKEN": "access-secret"
        ], snapshot: alphaSnapshot)
        let cleanDefault = codexAccountEnvironment(base: [
            "CODEX_HOME": "/terminal/home", "OPENAI_API_KEY": "openai-secret",
            "CODEX_API_KEY": "codex-secret", "CODEX_ACCESS_TOKEN": "access-secret"
        ], snapshot: defaultSnapshot)
        try require(cleanAlpha["CODEX_HOME"] == alphaSnapshot.home?.path &&
                    cleanAlpha["OPENAI_API_KEY"] == nil && cleanAlpha["CODEX_API_KEY"] == nil &&
                    cleanAlpha["CODEX_ACCESS_TOKEN"] == nil,
                    "Isolated Codex execution must use its own home and strip API credentials")
        try require(cleanDefault["CODEX_HOME"] == "/terminal/home" && cleanDefault["OPENAI_API_KEY"] == nil &&
                    cleanDefault["CODEX_API_KEY"] == nil && cleanDefault["CODEX_ACCESS_TOKEN"] == nil,
                    "The terminal account must retain CODEX_HOME while stripping API-key fallback")
        let cooldown = Date().addingTimeInterval(3600)
        try accounts.setRetryAt(cooldown, for: alpha.account.id)
        let alphaCooldown = try accounts.snapshot(id: alpha.account.id).account.retryAt
        let betaCooldown = try accounts.snapshot(id: beta.account.id).account.retryAt
        try require(alphaCooldown.map { abs($0.timeIntervalSince(cooldown)) < 0.01 } == true &&
                    betaCooldown == nil, "Account cooldowns must remain isolated")
        try accounts.setRetryAt(nil, for: alpha.account.id)

        let originalOpenAIKey = environment("OPENAI_API_KEY")
        let originalCodexKey = environment("CODEX_API_KEY")
        let originalAccessToken = environment("CODEX_ACCESS_TOKEN")
        defer {
            setEnvironment("OPENAI_API_KEY", originalOpenAIKey)
            setEnvironment("CODEX_API_KEY", originalCodexKey)
            setEnvironment("CODEX_ACCESS_TOKEN", originalAccessToken)
        }
        setEnvironment("OPENAI_API_KEY", "must-not-be-used")
        setEnvironment("CODEX_API_KEY", "must-not-be-used")
        setEnvironment("CODEX_ACCESS_TOKEN", "must-not-be-used")

        let accountLog = temp.appendingPathComponent("codex-account-env.log")
        let accountCodex = temp.appendingPathComponent("codex-account-fixture")
        let accountFixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Logged in using ChatGPT'
          exit 0
        fi
        printf '%s|%s|%s|%s|%s\\n' "${CODEX_HOME:-}" "${OPENAI_API_KEY:-}" "${CODEX_API_KEY:-}" "${CODEX_ACCESS_TOKEN:-}" "$*" >> '\(accountLog.path)'
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "--output-last-message" ]]; then
            printf '%s' '{"title":"Account Isolation","mom":"Account notes"}' > "$2"
            exit 0
          fi
          shift
        done
        exit 1
        """
        try accountFixture.write(to: accountCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: accountCodex.path)
        let accountConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: accountCodex)
        let alphaMeeting = try makeMeeting(root: root, status: "transcribed", speech: speech)
        let betaMeeting = try makeMeeting(root: root, status: "transcribed", speech: speech)
        setEnvironment("CATET_CODEX_ACCOUNT_ID", alpha.account.id)
        try require(try explicitMom(alphaMeeting, root: root, config: accountConfig) == "Account notes",
                    "Explicit MoM generation must run under the selected isolated account")
        setEnvironment("CATET_CODEX_ACCOUNT_ID", beta.account.id)
        try require(try explicitMom(betaMeeting, root: root, config: accountConfig) == "Account notes",
                    "Switching accounts must isolate the next Codex request")
        let accountRows = try String(contentsOf: accountLog, encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        try require(accountRows.count == 2 &&
                    accountRows[0].first == alphaSnapshot.home?.path &&
                    accountRows[1].first == betaSnapshot.home?.path &&
                    accountRows.allSatisfy { $0.count == 5 && $0[1].isEmpty && $0[2].isEmpty && $0[3].isEmpty &&
                        $0[4].contains("cli_auth_credentials_store") },
                    "Each Codex request must use its own home, file auth store, and no API-key fallback")
        let authCodex = temp.appendingPathComponent("codex-auth-fixture")
        let authCalls = temp.appendingPathComponent("codex-auth-calls")
        let authFixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Not authenticated'
          exit 0
        fi
        echo 'The Codex request must not run' >> '\(authCalls.path)'
        exit 1
        """
        try authFixture.write(to: authCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authCodex.path)
        let authConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: authCodex)
        let authMeeting = try makeMeeting(root: root, status: "transcribed", speech: speech)
        let oldAuthMinutes = Data("# Existing minutes\\n".utf8)
        try oldAuthMinutes.write(to: authMeeting.appendingPathComponent("mom.md"))
        setEnvironment("CATET_CODEX_ACCOUNT_ID", alpha.account.id)
        try rejects({ _ = try explicitMom(authMeeting, root: root, config: authConfig) },
                    "An unverified isolated account must not execute Codex")
        let authFailure = try readMetadata(from: authMeeting)
        try require(authFailure["error_kind"] as? String == "authentication" &&
                    authFailure["codex_account_id"] as? String == alpha.account.id &&
                    (authFailure["error"] as? String)?.contains("verified ChatGPT") == true,
                    "Authentication failures must be human-readable and identify the account snapshot")
        let unchangedAuthMinutes = try Data(contentsOf: authMeeting.appendingPathComponent("mom.md"))
        let unchangedAuthTranscript = try readTranscript(from: authMeeting).0
        try require(!FileManager.default.fileExists(atPath: authCalls.path) &&
                    unchangedAuthMinutes == oldAuthMinutes && unchangedAuthTranscript == speech,
                    "Authentication failure must avoid Codex execution and preserve existing outputs")
        let alphaState = try accounts.accounts().first(where: { $0.id == alpha.account.id })
        let betaState = try accounts.accounts().first(where: { $0.id == beta.account.id })
        try require(alphaState?.isAuthenticated == false && betaState?.isAuthenticated == true,
                    "A verified authentication failure must invalidate only that isolated account")
        try accounts.setAuthenticated(true, for: alpha.account.id)
        print("PASS: Authentication failures are truthful and stop isolated Codex execution")
        print("PASS: Codex account isolation and API-key stripping")

        let unknownCalls = temp.appendingPathComponent("codex-unknown-reset-calls")
        let unknownCodex = temp.appendingPathComponent("codex-unknown-reset-fixture")
        let unknownFixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Logged in using ChatGPT'
          exit 0
        fi
        echo 'attempt' >> '\(unknownCalls.path)'
        echo 'ERROR: You’ve hit your usage limit. Try again after an unknown interval.' >&2
        exit 1
        """
        try unknownFixture.write(to: unknownCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unknownCodex.path)
        let unknownConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: unknownCodex)
        let unknownMeeting = try makeMeeting(root: root, status: "transcribed", speech: speech)
        setEnvironment("CATET_CODEX_ACCOUNT_ID", alpha.account.id)
        try rejects({ _ = try explicitMom(unknownMeeting, root: root, config: unknownConfig) },
                    "An unknown usage reset must fail without scheduling a guessed retry")
        let unknownFailure = try readMetadata(from: unknownMeeting)
        try require(unknownFailure["status"] as? String == "failed" &&
                    unknownFailure["error_kind"] as? String == "usage_limit" &&
                    unknownFailure["retry_at"] is NSNull,
                    "An unparseable usage reset must persist a manual-recovery failure, not waiting status")
        let unknownAccountCooldown = try accounts.snapshot(id: alpha.account.id).account.retryAt
        let unknownCallCount = try String(contentsOf: unknownCalls, encoding: .utf8).split(separator: "\n").count
        try require(unknownAccountCooldown == nil && unknownCallCount == 1,
                    "Unknown reset must not create an account cooldown or an automatic retry loop")
        try require(try retryNotes(unknownMeeting, root: root, config: unknownConfig) == nil,
                    "Failed unknown-reset meetings must not be scheduled")

        let eventsPath = temp.appendingPathComponent("codex-error-events.jsonl")
        let eventCodex = temp.appendingPathComponent("codex-event-fixture")
        let eventFixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Logged in using ChatGPT' >&2
          exit 0
        fi
        cat '\(eventsPath.path)'
        exit 1
        """
        try eventFixture.write(to: eventCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: eventCodex.path)
        let eventConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: eventCodex)
        let eventMeeting = try makeMeeting(root: root, status: "transcribed", speech: speech)
        let misleadingEvents = """
        {"type":"item.completed","item":{"type":"agent_message","text":"PRIVATE TRANSCRIPT ERROR: usage limit. Try again at 10:01 AM."}}
        {"type":"turn.failed","error":{"message":"The network connection was interrupted."}}
        """
        try misleadingEvents.write(to: eventsPath, atomically: true, encoding: .utf8)
        try rejects({ _ = try explicitMom(eventMeeting, root: root, config: eventConfig) }, "A network failure must remain a failure")
        let eventFailure = try readMetadata(from: eventMeeting)
        try require(eventFailure["error_kind"] as? String == "codex" && eventFailure["retry_at"] is NSNull,
                    "Agent text mentioning limits must not fabricate a scheduled retry")
        try require((eventFailure["error"] as? String)?.contains("PRIVATE TRANSCRIPT") == false,
                    "Error events must not expose agent or transcript content in meeting metadata")
        try #"{"type":"error","message":"You’ve hit your usage limit. Try again at 11:59 PM."}"#.write(to: eventsPath, atomically: true, encoding: .utf8)
        try rejects({ _ = try explicitMom(eventMeeting, root: root, config: eventConfig) }, "Structured usage-limit events must stop generation")
        let structuredLimit = try readMetadata(from: eventMeeting)
        try require(structuredLimit["status"] as? String == "waiting_for_limit" && structuredLimit["error_kind"] as? String == "usage_limit",
                    "Authoritative structured provider errors must schedule the recommended future reset")
        try accounts.setRetryAt(nil, for: alpha.account.id)
        print("PASS: Structured provider errors schedule limits without trusting agent or transcript text")

        let limitCounter = temp.appendingPathComponent("codex-limit-attempts")
        let limitCodex = temp.appendingPathComponent("codex-limit-fixture")
        let limitFixture = """
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == *"login status"* ]]; then
          echo 'Logged in using ChatGPT'
          exit 0
        fi
        printf 'attempt\\n' >> '\(limitCounter.path)'
        sleep 0.4
        echo 'ERROR: You’ve hit your usage limit... try again at 11:59 PM.' >&2
        exit 1
        """
        try limitFixture.write(to: limitCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: limitCodex.path)
        let limitConfig = RuntimeConfig(ffmpeg: missing, whisper: missing, model: missing, vad: missing, codex: limitCodex)
        let firstRetry = try makeMeeting(root: root, status: "transcribed", speech: speech)
        let secondRetry = try makeMeeting(root: root, status: "transcribed", speech: speech)
        let preservedMinutes = Data("# Previously generated minutes\\n".utf8)
        try preservedMinutes.write(to: firstRetry.appendingPathComponent("mom.md"))
        setEnvironment("CATET_CODEX_ACCOUNT_ID", alpha.account.id)
        let group = DispatchGroup()
        for target in [firstRetry, secondRetry] {
            group.enter()
            DispatchQueue.global().async {
                _ = try? explicitMom(target, root: root, config: limitConfig)
                group.leave()
            }
        }
        try require(group.wait(timeout: .now() + .seconds(20)) == .success,
                    "Concurrent account jobs must finish after the serial Codex execution")
        let attemptCount = try String(contentsOf: limitCounter, encoding: .utf8).split(separator: "\n").count
        let firstFailure = try readMetadata(from: firstRetry)
        let secondFailure = try readMetadata(from: secondRetry)
        let accountCooldown = try accounts.snapshot(id: alpha.account.id).account.retryAt
        try require(attemptCount == 1 && accountCooldown.map { $0 > Date() } == true,
                    "A concurrent job must observe and honor the first job's durable account cooldown")
        try require(firstFailure["status"] as? String == "waiting_for_limit" &&
                    secondFailure["status"] as? String == "waiting_for_limit" &&
                    firstFailure["codex_account_id"] as? String == alpha.account.id &&
                    secondFailure["codex_account_id"] as? String == alpha.account.id,
                    "Limit failures must persist truthful waiting status and the account snapshot")
        let resetFormatter = ISO8601DateFormatter()
        resetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let persistedRetryAt = (firstFailure["retry_at"] as? String).flatMap(resetFormatter.date(from:)),
              let accountCooldown else {
            throw RegressionFailure(description: "A reliable usage reset must persist as UTC retry_at")
        }
        try require(abs(persistedRetryAt.timeIntervalSince(accountCooldown)) < 0.01,
                    "Meeting retry_at and the durable account cooldown must agree")
        try require((firstFailure["error"] as? String)?.contains("You’ve hit") == false &&
                    (firstFailure["error_kind"] as? String) == "usage_limit",
                    "Meeting metadata must contain a human-readable classification, not raw Codex diagnostics")
        let preservedTranscript = try readTranscript(from: firstRetry).0
        let actualPreservedMinutes = try Data(contentsOf: firstRetry.appendingPathComponent("mom.md"))
        try require(preservedTranscript == speech && actualPreservedMinutes == preservedMinutes,
                    "Usage-limit failures must preserve transcript and existing MoM output")
        let diagnosticMeeting = FileManager.default.fileExists(atPath: firstRetry.appendingPathComponent("codex.stderr.log").path)
            ? firstRetry : secondRetry
        let rawDiagnostic = try String(contentsOf: diagnosticMeeting.appendingPathComponent("codex.stderr.log"), encoding: .utf8)
        try require(rawDiagnostic.contains("You’ve hit your usage limit"),
                    "Raw Codex failure diagnostics must remain available in codex.stderr.log")
        print("PASS: Per-account serial execution, durable cooldown, and failure output preservation")

        try accounts.setRetryAt(Date().addingTimeInterval(3600), for: alpha.account.id)
        let scheduled = try makeMeeting(root: root, status: "waiting_for_limit", speech: speech,
                                        accountID: alpha.account.id, retryAt: Date().addingTimeInterval(3600))
        let callsBeforeGate = attemptCount
        try require(try retryNotes(scheduled, root: root, now: Date()) == nil,
                    "A future scheduled retry must be a successful no-op")
        try require(try String(contentsOf: limitCounter, encoding: .utf8).split(separator: "\n").count == callsBeforeGate,
                    "A scheduled retry before its due time must never invoke Codex")
        _ = try updateStatus(in: scheduled, status: "waiting_for_limit", values: [
            "retry_at": isoDateString(Date().addingTimeInterval(-1))
        ])
        try rejects({ _ = try retryNotes(scheduled, root: root, config: limitConfig) },
                    "An account cooldown must defer a due meeting without a remote request")
        let deferred = try readMetadata(from: scheduled)
        let callsAfterCooldown = try String(contentsOf: limitCounter, encoding: .utf8).split(separator: "\n").count
        try require(deferred["status"] as? String == "waiting_for_limit" &&
                    deferred["codex_account_id"] as? String == alpha.account.id &&
                    callsAfterCooldown == callsBeforeGate,
                    "Due retry must honor account cooldown and keep its original account snapshot")

        try accounts.setRetryAt(nil, for: alpha.account.id)
        _ = try updateStatus(in: scheduled, status: "waiting_for_limit", values: [
            "retry_at": isoDateString(Date().addingTimeInterval(-1))
        ])
        setEnvironment("CATET_CODEX_ACCOUNT_ID", beta.account.id)
        try require(try retryNotes(scheduled, root: root, config: accountConfig) == "Account notes",
                    "A due retry must run using its meeting's snapshotted account, not the newly selected account")
        let retried = try readMetadata(from: scheduled)
        let finalRows = try String(contentsOf: accountLog, encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        try require(retried["status"] as? String == "complete" &&
                    retried["codex_account_id"] as? String == alpha.account.id &&
                    finalRows.last?.first == alphaSnapshot.home?.path,
                    "Scheduled recovery must complete in the original account context")
        let hookRoot = temp.appendingPathComponent("hook-meetings")
        let hookMeeting = try makeMeeting(root: hookRoot, status: "transcribed", speech: speech)
        let hookReceiver = temp.appendingPathComponent("hook-receiver")
        let hookScript = temp.appendingPathComponent("hook-command")
        try """
        #!/bin/sh
        cat >> '\(hookReceiver.path)'
        exit 1
        """.write(to: hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookScript.path)
        let hookConfig: [String: Any] = ["command": [hookScript.path], "events": ["notes.ready"]]
        try JSONSerialization.data(withJSONObject: hookConfig).write(to: temp.appendingPathComponent("hooks.json"))
        _ = try updateStatus(in: hookMeeting, status: "complete")
        _ = try updateStatus(in: hookMeeting, status: "complete")
        do { try MeetingHooks.deliverPending(root: hookRoot) } catch { }
        let hookStatuses = try MeetingHooks.status(root: hookRoot)
        try require(hookStatuses.count == 1 && hookStatuses.first?["event"] as? String == "notes.ready",
                    "Repeated unchanged status must not duplicate the notes.ready event")
        try require(try readMetadata(from: hookMeeting)["status"] as? String == "complete",
                    "A command delivery failure must not change successful meeting status")
        print("PASS: Persisted hook transitions enqueue once and delivery failure preserves meeting success")
        print("PASS: Due-checked retry-notes uses meeting account and honors cooldown")
        print("PASS: Contextual title publication and invalid regeneration preserve prior results")
        print("All native engine regressions passed.")
    }
}
