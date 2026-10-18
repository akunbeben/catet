import Foundation
import Darwin
import Dispatch
@_silgen_name("flock")
private func meetingHooksFlock(_ descriptor: Int32, _ operation: Int32) -> Int32


/// Durable, local command hooks. Hooks receive one immutable JSON event on stdin.
enum MeetingHooks {
    private static let knownEvents: Set<String> = ["recording.saved", "transcript.ready", "notes.ready", "processing.failed"]
    private static let defaultTimeout: TimeInterval = 30
    private static let outputLimit = 64 * 1024
    private static let configLimit = 64 * 1024

    static func enqueue(event: String, directory: URL, metadata: [String: Any]) throws {
        guard knownEvents.contains(event) else { throw HookError.invalidEvent }
        let meetingDirectory = directory.standardizedFileURL
        let root = meetingDirectory.deletingLastPathComponent().standardizedFileURL
        guard meetingDirectory.path != root.path else { throw HookError.storage("The meeting directory is invalid.") }
        guard let config = try loadConfig(root: root) else { return }
        guard config.events.contains(event) else { return }

        let meetingInfo = try readMeetingInfo(directory: meetingDirectory)
        let files = try finalFiles(directory: meetingDirectory)
        let id = UUID().uuidString.lowercased()
        let occurredAt = timestamp(Date())
        var payload: [String: Any] = [
            "schema_version": 1,
            "id": id,
            "event": event,
            "occurred_at": occurredAt,
            "meeting": meetingInfo,
            "files": files
        ]
        if event == "processing.failed" {
            payload["failure"] = safeFailure(metadata["failure"] as? [String: Any], status: meetingInfo["status"] as? String)
        }
        let payloadData = try jsonData(payload)
        let commandData = try jsonData(config.command)
        let paths = try StoragePaths(root: root)
        try paths.prepare()
        try writeNewFile(payloadData, to: paths.event(id), mode: 0o600)
        do {
            try writeNewFile(commandData, to: paths.command(id), mode: 0o600)
            let record = HookJournal(id: id, event: event, status: "pending", attempts: 0,
                                     created_at: occurredAt, updated_at: occurredAt,
                                     last_error: nil, errors: [], diagnostic_path: nil)
            try writeJournal(record, to: paths.state(id))
        } catch {
            // An event without a journal is never visible to a worker; remove its partial snapshot.
            try? FileManager.default.removeItem(at: paths.event(id))
            try? FileManager.default.removeItem(at: paths.command(id))
            throw error
        }
    }

    static func deliverPending(root: URL) throws {
        try deliverPending(root: root, timeout: defaultTimeout)
    }

    /// The timeout overload is internal so regression tests can exercise timeout handling quickly.
    static func deliverPending(root: URL, timeout: TimeInterval) throws {
        guard try loadConfig(root: root) != nil else { return }
        let paths = try StoragePaths(root: root)
        try paths.prepare()
        let lock = try paths.acquireDeliveryLock()
        guard lock >= 0 else { return }
        defer { paths.releaseDeliveryLock(lock) }
        try deliverLocked(paths: paths, timeout: timeout)
    }

    static func retryFailed(root: URL) throws {
        guard try loadConfig(root: root) != nil else { return }
        let paths = try StoragePaths(root: root)
        guard paths.hasStateDirectory else { return }
        let lock = try paths.acquireDeliveryLock(createDirectories: true)
        guard lock >= 0 else { return }
        defer { paths.releaseDeliveryLock(lock) }
        for var record in try journals(paths: paths) where record.status == "failed" {
            record.status = "pending"
            record.updated_at = timestamp(Date())
            try writeJournal(record, to: paths.state(record.id))
        }
        try deliverLocked(paths: paths, timeout: defaultTimeout)
    }

    /// Read-only: this method does not acquire the delivery lock or execute queued commands.
    static func status(root: URL) throws -> [[String: Any]] {
        _ = try loadConfig(root: root)
        let paths = try StoragePaths(root: root)
        guard paths.hasStateDirectory else { return [] }
        return try journals(paths: paths).sorted { $0.created_at < $1.created_at }.map { record in
            var item: [String: Any] = [
                "id": record.id,
                "event": record.event,
                "status": record.status,
                "attempts": record.attempts,
                "created_at": record.created_at,
                "updated_at": record.updated_at,
                "errors": record.errors
            ]
            if let error = record.last_error { item["error"] = error; item["last_error"] = error }
            if let path = record.diagnostic_path { item["diagnostic_path"] = path }
            return item
        }
    }

    private static func deliverLocked(paths: StoragePaths, timeout: TimeInterval) throws {
        var failures: [String] = []
        for record in try journals(paths: paths) where record.status == "pending" || record.status == "delivering" {
            var current = record
            if current.status == "delivering" {
                let interrupted = "Delivery was interrupted; the outcome is unknown. Retrying with the same event ID may repeat side effects."
                current.status = "pending"
                addError(interrupted, to: &current)
                current.updated_at = timestamp(Date())
                try writeJournal(current, to: paths.state(current.id))
            }
            do {
                try deliverOne(&current, paths: paths, timeout: timeout)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw HookError.delivery(failures.joined(separator: " "))
        }
    }

    private static func deliverOne(_ record: inout HookJournal, paths: StoragePaths, timeout: TimeInterval) throws {
        let payloadURL = paths.event(record.id)
        let commandURL = paths.command(record.id)
        let payloadData = try readRegularFile(payloadURL, limit: 2 * 1024 * 1024)
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["id"] as? String == record.id,
              payload["event"] as? String == record.event else {
            throw HookError.storage("A queued hook event is invalid.")
        }
        let commandData = try readRegularFile(commandURL, limit: configLimit)
        guard let command = try JSONSerialization.jsonObject(with: commandData) as? [String],
              validCommand(command) else {
            markFailure(&record, message: "The saved hook command is invalid.", diagnosticPath: nil, paths: paths)
            throw HookError.delivery("The saved hook command is invalid.")
        }

        record.status = "delivering"
        record.attempts += 1
        record.updated_at = timestamp(Date())
        try writeJournal(record, to: paths.state(record.id))

        let result: HookCommandResult
        do {
            result = try run(command: command, input: payloadURL, timeout: max(0.05, timeout))
        } catch {
            let message = "Could not start the hook command: \(error.localizedDescription)"
            let diagnostic = try? writeDiagnostic(HookCommandResult(exitStatus: nil, timedOut: false,
                                                                 stdout: Data(), stderr: Data(message.utf8), stdoutDropped: 0, stderrDropped: 0),
                                                   id: record.id, attempt: record.attempts, paths: paths)
            markFailure(&record, message: message, diagnosticPath: diagnostic, paths: paths)
            throw HookError.delivery(message)
        }

        guard !result.timedOut, result.exitStatus == 0 else {
            let message: String
            if result.timedOut {
                message = "The hook command timed out after \(max(0.05, timeout)) seconds and was terminated."
            } else if let status = result.exitStatus {
                message = "The hook command exited with status \(status)."
            } else {
                message = "The hook command ended without an exit status."
            }
            let diagnostic = try? writeDiagnostic(result, id: record.id, attempt: record.attempts, paths: paths)
            let actionable = diagnostic.map { "\(message) Diagnostics: \($0)" } ?? message
            markFailure(&record, message: actionable, diagnosticPath: diagnostic, paths: paths)
            throw HookError.delivery(actionable)
        }

        record.status = "delivered"
        record.updated_at = timestamp(Date())
        try writeJournal(record, to: paths.state(record.id))
    }

    private static func run(command: [String], input: URL, timeout: TimeInterval) throws -> HookCommandResult {
        guard validCommand(command), FileManager.default.isExecutableFile(atPath: command[0]) else {
            throw HookError.storage("The configured executable is unavailable or not executable.")
        }
        let inputFD = open(input.path, O_RDONLY | O_NOFOLLOW)
        guard inputFD >= 0 else { throw HookError.storage("Could not open the queued event for stdin.") }
        defer { _ = Darwin.close(inputFD) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReader = stdoutPipe.fileHandleForReading
        let stdoutWriter = stdoutPipe.fileHandleForWriting
        let stderrReader = stderrPipe.fileHandleForReading
        let stderrWriter = stderrPipe.fileHandleForWriting
        let stdoutRead = stdoutReader.fileDescriptor
        let stdoutWrite = stdoutWriter.fileDescriptor
        let stderrRead = stderrReader.fileDescriptor
        let stderrWrite = stderrWriter.fileDescriptor
        let stdoutCapture = StreamCapture(fd: stdoutRead, limit: outputLimit)
        let stderrCapture = StreamCapture(fd: stderrRead, limit: outputLimit)
        var stdoutWriterOpen = true
        var stderrWriterOpen = true
        defer {
            if stdoutWriterOpen { stdoutWriter.closeFile() }
            if stderrWriterOpen { stderrWriter.closeFile() }
            _ = stdoutCapture.waitUntilFinished(seconds: 0.5)
            _ = stderrCapture.waitUntilFinished(seconds: 0.5)
            stdoutReader.closeFile()
            stderrReader.closeFile()
        }

        var actions: posix_spawn_file_actions_t?
        var actionStatus = posix_spawn_file_actions_init(&actions)
        guard actionStatus == 0 else { throw HookError.storage(posixText(actionStatus)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        actionStatus = posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO)
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO) }
        for descriptor in [inputFD, stdoutRead, stderrRead, stdoutWrite, stderrWrite] where actionStatus == 0 {
            actionStatus = posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        guard actionStatus == 0 else { throw HookError.storage(posixText(actionStatus)) }

        var attributes: posix_spawnattr_t?
        var attrStatus = posix_spawnattr_init(&attributes)
        guard attrStatus == 0 else { throw HookError.storage(posixText(attrStatus)) }
        defer { posix_spawnattr_destroy(&attributes) }
        attrStatus = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        if attrStatus == 0 { attrStatus = posix_spawnattr_setpgroup(&attributes, 0) }
        guard attrStatus == 0 else { throw HookError.storage(posixText(attrStatus)) }

        let environment = filteredEnvironment(ProcessInfo.processInfo.environment)
        let commandPointers = try command.map { value -> UnsafeMutablePointer<CChar> in
            guard let pointer = strdup(value) else { throw HookError.storage("Could not prepare the hook command.") }
            return pointer
        }
        let environmentPointers = try environment.keys.sorted().map { key -> UnsafeMutablePointer<CChar> in
            guard let pointer = strdup("\(key)=\(environment[key]!)") else { throw HookError.storage("Could not prepare the hook environment.") }
            return pointer
        }
        defer { commandPointers.forEach { free($0) }; environmentPointers.forEach { free($0) } }
        var argv = commandPointers.map(Optional.some); argv.append(nil)
        var envp = environmentPointers.map(Optional.some); envp.append(nil)

        var processID = pid_t()
        let spawnStatus = command[0].withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(&processID, executable, &actions, &attributes,
                                argvBuffer.baseAddress!, envBuffer.baseAddress!)
                }
            }
        }
        guard spawnStatus == 0 else { throw HookError.storage("posix_spawn: \(posixText(spawnStatus))") }
        // The child owns dup'd pipe writers; close the parent's copies immediately so EOF works.
        stdoutWriter.closeFile(); stdoutWriterOpen = false
        stderrWriter.closeFile(); stderrWriterOpen = false

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var reaped = false
        var timedOut = false
        while !reaped {
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID { reaped = true; break }
            if result < 0 && errno != EINTR { break }
            if Date() >= deadline {
                timedOut = true
                _ = kill(-processID, SIGTERM)
                let grace = Date().addingTimeInterval(0.25)
                while Date() < grace {
                    let termResult = waitpid(processID, &waitStatus, WNOHANG)
                    if termResult == processID { reaped = true; break }
                    if termResult < 0 && errno != EINTR { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if !reaped { _ = kill(-processID, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !reaped {
            while waitpid(processID, &waitStatus, 0) < 0 && errno == EINTR {}
        }
        // Stop descendants that inherited the pipes, then let the bounded readers drain EOF.
        _ = kill(-processID, SIGKILL)
        _ = stdoutCapture.waitUntilFinished(seconds: 1.5)
        _ = stderrCapture.waitUntilFinished(seconds: 1.5)

        let exitStatus: Int?
        if (waitStatus & 0x7f) == 0 { exitStatus = Int((waitStatus >> 8) & 0xff) }
        else { exitStatus = 128 + Int(waitStatus & 0x7f) }
        return HookCommandResult(exitStatus: exitStatus, timedOut: timedOut,
                             stdout: stdoutCapture.data, stderr: stderrCapture.data,
                             stdoutDropped: stdoutCapture.dropped, stderrDropped: stderrCapture.dropped)
    }

    private static func filteredEnvironment(_ source: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in source {
            guard !containsSecretName(key), !key.contains("="), !key.contains("\0"), !value.contains("\0") else { continue }
            result[key] = value
        }
        return result
    }

    private static func containsSecretName(_ key: String) -> Bool {
        let name = key.uppercased().replacingOccurrences(of: "-", with: "_")
        if name == "CODEX_HOME" || name == "CODEX_ACCOUNT_ID" { return true }
        return ["API_KEY", "APIKEY", "ACCESS_TOKEN", "REFRESH_TOKEN", "ID_TOKEN", "AUTH_TOKEN",
                "TOKEN", "ACCESS_KEY", "KEY_ID", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL",
                "AUTHORIZATION", "AUTH_SOCK", "SSH_AGENT", "PRIVATE_KEY", "COOKIE", "BEARER", "KUBECONFIG"].contains { name.contains($0) }
    }

    private static func loadConfig(root: URL) throws -> HookConfig? {
        let url = root.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("hooks.json")
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw HookError.configuration("Could not inspect hooks.json.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw HookError.configuration("hooks.json must be a regular file, not a symlink.")
        }
        let data = try readRegularFile(url, limit: configLimit)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.configuration("hooks.json must be a JSON object.")
        }
        let unknown = Set(object.keys).subtracting(["command", "events"])
        guard unknown.isEmpty else { throw HookError.configuration("hooks.json contains an unknown setting.") }
        guard let command = object["command"] as? [String], validCommand(command) else {
            throw HookError.configuration("hooks.json command must be a nonempty array with an absolute executable path and NUL-free arguments.")
        }
        let events: [String]
        if let rawEvents = object["events"] {
            guard let values = rawEvents as? [String],
                  Set(values).count == values.count, values.allSatisfy({ knownEvents.contains($0) }) else {
                throw HookError.configuration("hooks.json events must be a unique list of known event names.")
            }
            events = values
        } else {
            events = knownEvents.sorted()
        }
        return HookConfig(command: command, events: events)
    }

    private static func validCommand(_ command: [String]) -> Bool {
        guard let executable = command.first, executable.hasPrefix("/"), executable != "/",
              command.allSatisfy({ !$0.contains("\0") }) else { return false }
        return true
    }

    private static func readMeetingInfo(directory: URL) throws -> [String: Any] {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw HookError.storage("The meeting directory must be a real directory.")
        }
        let root = directory.deletingLastPathComponent()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw HookError.storage("The meetings root must be a real directory.")
        }
        let metadataURL = directory.appendingPathComponent("meeting.json")
        let data = try readRegularFile(metadataURL, limit: 1024 * 1024)
        guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = metadata["id"] as? String, !id.isEmpty, id.utf8.count <= 256 else {
            throw HookError.storage("The meeting metadata is invalid.")
        }
        let title = (metadata["title"] as? String).flatMap { $0.utf8.count <= 4096 ? $0 : nil } ?? id
        let status = (metadata["status"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil } ?? "unknown"
        return ["id": id, "title": title, "status": status, "directory": directory.path]
    }

    private static func finalFiles(directory: URL) throws -> [String: Any] {
        var files: [String: Any] = [:]
        let names: [(String, String)] = [
            ("metadata", "meeting.json"), ("transcript_json", "transcript.json"),
            ("transcript_text", "transcript.txt"), ("notes", "mom.md")
        ]
        for (key, name) in names {
            let url = directory.appendingPathComponent(name)
            if try isRegularFileWithoutSymlink(url) { files[key] = url.path }
        }
        for channel in ["microphone", "system"] {
            let archived = directory.appendingPathComponent(channel + ".ogg")
            let capture = directory.appendingPathComponent(channel + ".wav")
            if try isRegularFileWithoutSymlink(archived) { files[channel] = archived.path }
            else if try isRegularFileWithoutSymlink(capture) { files[channel] = capture.path }
        }
        let allowedInputExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "mp4", "mov", "aiff", "wma"]
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let inputs = try children.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("input."), allowedInputExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return try isRegularFileWithoutSymlink(url)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(\.path)
        if !inputs.isEmpty { files["input"] = inputs }
        return files
    }

    private static func safeFailure(_ details: [String: Any]?, status: String?) -> [String: Any] {
        let rawKind = details?["kind"] as? String ?? details?["error_kind"] as? String ?? "processing"
        let kind = safeIdentifier(rawKind) ?? "processing"
        let rawStep = details?["step"] as? String ?? details?["failed_step"] as? String
        var failure: [String: Any] = ["kind": kind, "message": failureMessage(kind: kind, status: status)]
        if let step = rawStep.flatMap(safeIdentifier) { failure["step"] = step }
        if let retryAt = details?["retry_at"] as? String, retryAt.utf8.count <= 128,
           ISO8601DateFormatter().date(from: retryAt) != nil { failure["retry_at"] = retryAt }
        return failure
    }

    private static func safeIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) ||
                  (scalar.value >= 97 && scalar.value <= 122) || scalar == "-" || scalar == "_"
              }) else { return nil }
        return value
    }

    private static func failureMessage(kind: String, status: String?) -> String {
        switch kind {
        case "authentication": return "Sign in to Codex again to continue processing."
        case "transcription": return "The recording could not be transcribed. Your audio is still saved."
        case "usage_limit": return "This Codex account has reached its usage limit."
        case "interrupted": return "Processing stopped before it finished. You can try again."
        case "notes", "summarization": return "Meeting notes could not be created. You can try again."
        case "capture", "recording": return "The recording could not be finalized."
        default: return status == "waiting_for_limit" ? "Processing is waiting for the account usage limit to reset." : "Meeting processing failed. You can try again."
        }
    }

    private static func markFailure(_ record: inout HookJournal, message: String, diagnosticPath: String?, paths: StoragePaths) {
        record.status = "failed"
        record.updated_at = timestamp(Date())
        addError(message, to: &record)
        if let diagnosticPath { record.diagnostic_path = diagnosticPath }
        try? writeJournal(record, to: paths.state(record.id))
    }

    private static func addError(_ message: String, to record: inout HookJournal) {
        let retained = String(message.prefix(1024))
        record.last_error = retained
        record.errors.append(retained)
        if record.errors.count > 50 { record.errors.removeFirst(record.errors.count - 50) }
    }

    private static func writeDiagnostic(_ result: HookCommandResult, id: String, attempt: Int, paths: StoragePaths) throws -> String {
        let object: [String: Any] = [
            "event_id": id,
            "attempt": attempt,
            "exit_status": result.exitStatus as Any? ?? NSNull(),
            "timed_out": result.timedOut,
            "stdout": String(data: result.stdout, encoding: .utf8) ?? result.stdout.base64EncodedString(),
            "stderr": String(data: result.stderr, encoding: .utf8) ?? result.stderr.base64EncodedString(),
            "stdout_truncated_bytes": result.stdoutDropped,
            "stderr_truncated_bytes": result.stderrDropped
        ]
        let url = paths.log(id, attempt)
        try writeNewFile(jsonData(object), to: url, mode: 0o600)
        return url.path
    }

    private static func journals(paths: StoragePaths) throws -> [HookJournal] {
        guard paths.hasStateDirectory else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.stateDirectory.path)
        var result: [HookJournal] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard UUID(uuidString: id) != nil else { throw HookError.storage("The hook journal contains an invalid event identifier.") }
            let data = try readRegularFile(paths.state(id), limit: 512 * 1024)
            let record: HookJournal
            do { record = try JSONDecoder().decode(HookJournal.self, from: data) }
            catch { throw HookError.storage("A hook delivery status file is invalid.") }
            guard record.id == id, knownEvents.contains(record.event),
                  ["pending", "delivering", "delivered", "failed"].contains(record.status), record.attempts >= 0 else {
                throw HookError.storage("A hook delivery status file is invalid.")
            }
            result.append(record)
        }
        return result
    }

    private static func writeJournal(_ record: HookJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(encoder.encode(record), to: url, mode: 0o600)
    }

    private static func jsonData(_ value: Any) throws -> Data {
        do { return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
        catch { throw HookError.storage("Could not encode a hook event.") }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw HookError.storage("A required hook file is missing.") }
            throw HookError.storage("Could not open a hook file safely.")
        }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw HookError.storage("A hook file is not a regular file or exceeds its size limit.")
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress!, raw.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw HookError.storage("Could not read a hook file.")
            }
            guard data.count + count <= limit else { throw HookError.storage("A hook file exceeds its size limit.") }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw HookError.storage("Could not inspect a meeting output safely.")
        }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func writeNewFile(_ data: Data, to url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw HookError.storage("Could not create a private hook file.") }
        var succeeded = false
        defer {
            _ = Darwin.close(fd)
            if !succeeded { _ = unlink(url.path) }
        }
        guard fchmod(fd, mode) == 0 else { throw HookError.storage("Could not secure a hook file.") }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw HookError.storage("Could not persist a hook file.") }
        try syncHookDirectory(url.deletingLastPathComponent())
        succeeded = true
    }

    private static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try writeNewFile(data, to: temp, mode: mode)
        guard rename(temp.path, url.path) == 0 else {
            _ = unlink(temp.path)
            throw HookError.storage("Could not atomically update hook status.")
        }
        try syncHookDirectory(url.deletingLastPathComponent())
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw HookError.storage("Could not write a hook file.")
                }
                offset += count
            }
        }
    }

    private static func posixText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

private struct HookConfig {
    let command: [String]
    let events: [String]
}

private struct HookJournal: Codable {
    let id: String
    let event: String
    var status: String
    var attempts: Int
    let created_at: String
    var updated_at: String
    var last_error: String?
    var errors: [String]
    var diagnostic_path: String?
}

private struct HookCommandResult {
    let exitStatus: Int?
    let timedOut: Bool
    let stdout: Data
    let stderr: Data
    let stdoutDropped: Int
    let stderrDropped: Int
}

private enum HookError: Error, LocalizedError {
    case invalidEvent
    case configuration(String)
    case storage(String)
    case delivery(String)

    var errorDescription: String? {
        switch self {
        case .invalidEvent: return "The hook event name is not supported."
        case let .configuration(message), let .storage(message), let .delivery(message): return message
        }
    }
}

private final class StreamCapture {
    private let fd: Int32
    private let limit: Int
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var captured = Data()
    private var truncated = 0

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = limit
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(self.fd, raw.baseAddress!, raw.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                self.lock.lock()
                let amount = min(count, max(0, self.limit - self.captured.count))
                if amount > 0 { self.captured.append(contentsOf: buffer[0..<amount]) }
                self.truncated += count - amount
                self.lock.unlock()
            }
            self.finished.leave()
        }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return captured }
    var dropped: Int { lock.lock(); defer { lock.unlock() }; return truncated }
    func waitUntilFinished(seconds: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + seconds) == .success
    }
}

private struct StoragePaths {
    let root: URL
    let runtime: URL
    let hooks: URL
    let directory: URL
    let events: URL
    let commands: URL
    let stateDirectory: URL
    let logs: URL

    init(root: URL) throws {
        let meetingRoot = root.standardizedFileURL
        let component = meetingRoot.lastPathComponent
        guard !component.isEmpty else { throw HookError.storage("The meetings root is invalid.") }
        let identifier: String
        if component.utf8.count <= 100 {
            identifier = "r-" + component.utf8.map { String(format: "%02x", $0) }.joined()
        } else {
            var hash: UInt64 = 14695981039346656037
            for byte in meetingRoot.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            identifier = "r-long-\(String(hash, radix: 16))"
        }
        let parent = meetingRoot.deletingLastPathComponent()
        self.root = meetingRoot
        runtime = parent.appendingPathComponent("runtime", isDirectory: true)
        hooks = runtime.appendingPathComponent("hooks", isDirectory: true)
        directory = hooks.appendingPathComponent(identifier, isDirectory: true)
        events = directory.appendingPathComponent("events", isDirectory: true)
        commands = directory.appendingPathComponent("commands", isDirectory: true)
        stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        logs = directory.appendingPathComponent("logs", isDirectory: true)
    }

    var hasStateDirectory: Bool {
        Self.isDirectoryWithoutSymlink(runtime) && Self.isDirectoryWithoutSymlink(hooks) &&
        Self.isDirectoryWithoutSymlink(directory) && Self.isDirectoryWithoutSymlink(stateDirectory)
    }

    func prepare() throws {
        for url in [runtime, hooks, directory, events, commands, stateDirectory, logs] {
            try Self.ensurePrivateDirectory(url)
        }
    }

    func event(_ id: String) -> URL { events.appendingPathComponent("\(id).json") }
    func command(_ id: String) -> URL { commands.appendingPathComponent("\(id).json") }
    func state(_ id: String) -> URL { stateDirectory.appendingPathComponent("\(id).json") }
    func log(_ id: String, _ attempt: Int) -> URL { logs.appendingPathComponent("\(id)-\(attempt).json") }

    func acquireDeliveryLock(createDirectories: Bool = false) throws -> Int32 {
        if createDirectories { try prepare() }
        else if !Self.isDirectoryWithoutSymlink(directory) { return -1 }
        let url = directory.appendingPathComponent("delivery.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HookError.storage("Could not open the hook delivery lock.") }
        _ = fchmod(fd, 0o600)
        if meetingHooksFlock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            _ = Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return -1 }
            throw HookError.storage("Could not acquire the hook delivery lock.")
        }
        return fd
    }

    func releaseDeliveryLock(_ fd: Int32) {
        _ = meetingHooksFlock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw HookError.storage("Could not create private hook storage.") }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw HookError.storage("Hook storage must not contain symlinks or non-directory paths.")
        }
        guard chmod(url.path, 0o700) == 0 else { throw HookError.storage("Could not secure hook storage permissions.") }
        try syncHookDirectory(url.deletingLastPathComponent())
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
private func syncHookDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw HookError.storage("Could not open private hook storage for syncing.") }
    defer { _ = Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          fsync(fd) == 0 else {
        throw HookError.storage("Could not persist hook storage changes.")
    }
}
