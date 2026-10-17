import Foundation
import Darwin
import AVFoundation
@_silgen_name("flock")
func catetFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct Meeting: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var created_at: String
    var status: String
    var error: String?
    var capture_warning: String?
    var generate_mom: Bool?
    var error_kind: String?
    var retry_at: String?
    var codex_account_id: String?
    var failed_step: String?
    var directory: URL
    enum CodingKeys: String, CodingKey { case id, title, created_at, status, error, capture_warning, generate_mom, error_kind, retry_at, codex_account_id, failed_step }
    init(id: String, title: String, created_at: String, status: String, error: String? = nil, capture_warning: String? = nil, generate_mom: Bool? = nil, directory: URL) {
        self.id = id; self.title = title; self.created_at = created_at; self.status = status; self.error = error; self.capture_warning = capture_warning; self.generate_mom = generate_mom; self.directory = directory
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        created_at = try c.decode(String.self, forKey: .created_at); status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error); generate_mom = try c.decodeIfPresent(Bool.self, forKey: .generate_mom)
        capture_warning = try c.decodeIfPresent(String.self, forKey: .capture_warning)
        error_kind = try c.decodeIfPresent(String.self, forKey: .error_kind)
        retry_at = try c.decodeIfPresent(String.self, forKey: .retry_at)
        codex_account_id = try c.decodeIfPresent(String.self, forKey: .codex_account_id)
        failed_step = try c.decodeIfPresent(String.self, forKey: .failed_step)
        directory = URL(fileURLWithPath: "/")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(created_at, forKey: .created_at)
        try c.encode(status, forKey: .status); try c.encodeIfPresent(error, forKey: .error); try c.encodeIfPresent(generate_mom, forKey: .generate_mom)
        try c.encodeIfPresent(capture_warning, forKey: .capture_warning)
        try c.encodeIfPresent(error_kind, forKey: .error_kind)
        try c.encodeIfPresent(retry_at, forKey: .retry_at)
        try c.encodeIfPresent(codex_account_id, forKey: .codex_account_id)
        try c.encodeIfPresent(failed_step, forKey: .failed_step)
    }

    private static let retryDateFormatter = ISO8601DateFormatter()
    var retryDate: Date? { retry_at.flatMap { Self.retryDateFormatter.date(from: $0) } }
    var isUsageLimited: Bool {
        error_kind == "usage_limit" || (error?.localizedCaseInsensitiveContains("hit your usage limit") == true)
    }
    var failureMessage: String? {
        guard let error, !error.isEmpty else { return nil }
        if isUsageLimited { return "This Codex account has reached its usage limit." }
        switch error_kind {
        case "authentication": return "Sign in to Codex again to create meeting notes."
        case "transcription": return "The recording could not be transcribed. Your audio is still saved. Choose Retry transcription to try again."
        case "interrupted": return "Processing stopped before it finished. You can try again."
        default:
            if failed_step == "mom" || error.contains("Codex") {
                return "Meeting notes could not be created. Your transcript is still available."
            }
            return "Processing could not finish. Your saved files are still available."
        }
    }
    var statusLabel: String {
        switch status {
        case "recording": return "Recording"
        case "transcribing": return "Transcribing"
        case "waiting_for_limit": return "Waiting for Codex"
        case "transcribed": return "Transcript ready"
        case "summarizing": return "Creating notes"
        default: return status.capitalized
        }
    }
}


final class MeetingStore {
    private let fm = FileManager.default
    let root: URL
    private let lock = NSLock()
    private var activeProcessIDs = Set<String>()
    private var activeProcesses: [String: Process] = [:]
    private var reservedMeetingLocks: [String: Int32] = [:]
    init() {
        if let path = ProcessInfo.processInfo.environment["CATET_MEETINGS_ROOT"], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catet/meetings", isDirectory: true)
        }
    }
    func createRoot() throws { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
    func reserveForLiveTranscription(_ meetingID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !activeProcessIDs.contains(meetingID), reservedMeetingLocks[meetingID] == nil,
              let meeting = loadAll().first(where: { $0.id == meetingID }),
              !isProcessRunning(for: meeting) else {
            throw StoreError.processing("This meeting is already being processed or recorded.")
        }
        let locks = root.deletingLastPathComponent().appendingPathComponent("runtime/locks", isDirectory: true)
        try fm.createDirectory(at: locks, withIntermediateDirectories: true)
        let descriptor = open(locks.appendingPathComponent("\(meetingID).lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.processing("Could not reserve this meeting for transcription.") }
        guard catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StoreError.processing("This meeting is already being processed or recorded.")
        }
        var pid = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = pid.withUTF8 { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        reservedMeetingLocks[meetingID] = descriptor
    }
    func releaseLiveTranscriptionReservation(_ meetingID: String) {
        lock.lock()
        if let descriptor = reservedMeetingLocks.removeValue(forKey: meetingID) {
            _ = catetFlock(descriptor, LOCK_UN)
            close(descriptor)
        }
        lock.unlock()
    }
    /// Live failures are provisional until one full pass over the saved audio has failed.
    func finishTranscription(
        meeting: Meeting,
        finishLive: () async throws -> Void,
        cancelLive: () async -> Void
    ) async throws {
        defer { releaseLiveTranscriptionReservation(meeting.id) }
        do {
            try await finishLive()
        } catch {
            fputs("catet: live transcription failed; retrying saved audio: \(error.localizedDescription)\n", stderr)
            await cancelLive()
            // A failed publication may have left only one final output. Never let the
            // engine mistake it for a complete transcript and skip the saved audio.
            for name in ["transcript.json", "transcript.txt", "live-transcript.json", "live-transcript.txt"] {
                let path = meeting.directory.appendingPathComponent(name)
                do { try fm.removeItem(at: path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
            }
            try update(id: meeting.id) {
                $0.status = "recorded"; $0.error = nil; $0.error_kind = nil
                $0.failed_step = nil; $0.retry_at = nil
            }
            // The engine takes the canonical lock itself. Keep the recording UI
            // active until its completion, including when the user is quitting.
            releaseLiveTranscriptionReservation(meeting.id)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runEngine(meeting: meeting, command: "process", transcriptOnly: true) {
                    continuation.resume(with: $0)
                }
            }
            return
        }
        try update(id: meeting.id) {
            $0.status = "transcribed"; $0.error = nil; $0.error_kind = nil
            $0.failed_step = nil; $0.retry_at = nil
        }
    }
    func meeting(id: String) -> Meeting? { loadAll().first { $0.id == id } }
    func newMeeting(title: String, generateMoM: Bool = false) throws -> Meeting {
        let id = UUID().uuidString.lowercased(), dir = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = Meeting(id: id, title: title, created_at: ISO8601DateFormatter().string(from: Date()), status: "recording", generate_mom: generateMoM, directory: dir)
        try persist(m)
        return m
    }
    func loadAll() -> [Meeting] {
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")), var m = try? JSONDecoder().decode(Meeting.self, from: data) else { return nil }
            m.directory = dir; return m
        }.sorted { $0.created_at > $1.created_at }
    }
    func loadAndRecover() -> [Meeting] {
        var all = loadAll()
        for i in all.indices {
            let status = all[i].status
            if status == "recording" {
                if isLocallyProcessing(all[i].id) { continue }
                all[i].status = "recorded"
                if !fm.fileExists(atPath: all[i].directory.appendingPathComponent("microphone.wav").path) && !fm.fileExists(atPath: all[i].directory.appendingPathComponent("system.wav").path) {
                    all[i].error = "The app stopped before audio was finalized. No complete recording is available."
                } else { all[i].error = "Catet restarted during recording. Available audio was preserved; retry transcription to continue." }
                do { try persist(all[i]) } catch { all[i].error = "Could not save recovery state: \(error.localizedDescription)" }
            } else if status == "transcribing" || status == "summarizing" {
                if !isLocallyProcessing(all[i].id) {
                    all[i].status = "failed"; all[i].error = "Processing stopped before it completed. Retry the action to continue."
                    all[i].error_kind = "interrupted"; all[i].failed_step = status == "transcribing" ? "transcribe" : "mom"
                    all[i].retry_at = nil
                    do { try persist(all[i]) } catch { all[i].error = "Could not save recovery state: \(error.localizedDescription)" }
                }
            }
        }
        return all
    }
    func update(id: String, _ change: (inout Meeting) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = loadAll().first(where: { $0.id == id }) else { throw StoreError.configuration("Meeting metadata is unavailable.") }
        let dir = root.appendingPathComponent(id, isDirectory: true); m.directory = dir; change(&m)
        try write(m, in: dir)
    }
    func recordingDuration(for meeting: Meeting) -> TimeInterval? {
        ["microphone.wav", "system.wav"].compactMap { name -> TimeInterval? in
            guard let audio = try? AVAudioFile(forReading: meeting.directory.appendingPathComponent(name)),
                  audio.processingFormat.sampleRate > 0 else { return nil }
            return Double(audio.length) / audio.processingFormat.sampleRate
        }.max()
    }

    @discardableResult
    func moveToTrash(ids: Set<String>, onlyUnprocessedRecordings: Bool = false) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let root = self.root.standardizedFileURL.resolvingSymlinksInPath()
        let locks = self.root.deletingLastPathComponent().appendingPathComponent("runtime/locks", isDirectory: true)
        try fm.createDirectory(at: locks, withIntermediateDirectories: true)
        var descriptors: [Int32] = []
        defer {
            for descriptor in descriptors {
                _ = catetFlock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        var directories: [URL] = []
        for id in ids {
            let directory = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard directory.lastPathComponent == id, directory.deletingLastPathComponent() == root else {
                throw StoreError.configuration("The meeting is outside the meeting library. Nothing was moved to Trash.")
            }
            guard !activeProcessIDs.contains(id), reservedMeetingLocks[id] == nil else {
                throw StoreError.processing("A selected meeting is still being processed. Wait for it to finish, then try again. Nothing was moved to Trash.")
            }
            let descriptor = open(locks.appendingPathComponent("\(id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw StoreError.processing("Could not check whether a selected meeting is in use. Nothing was moved to Trash.") }
            guard catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw StoreError.processing("A selected meeting is still in use. Stop recording or wait for processing to finish, then try again. Nothing was moved to Trash.")
            }
            descriptors.append(descriptor)
            let current = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
            guard current.id == id,
                  !["recording", "transcribing", "summarizing"].contains(current.status),
                  !onlyUnprocessedRecordings || current.status == "recorded" else {
                throw StoreError.processing("A selected meeting changed or is still recording or processing. Refresh the library and try again. Nothing was moved to Trash.")
            }
            directories.append(directory)
        }
        var trashed: [URL] = []
        for directory in directories {
            do {
                var url: NSURL?
                try fm.trashItem(at: directory, resultingItemURL: &url)
                if let url { trashed.append(url as URL) }
            } catch {
                throw StoreError.processing("Could not move every selected meeting to Trash. Meetings already moved can be restored from Trash. \(error.localizedDescription)")
            }
        }
        return trashed
    }
    private func persist(_ m: Meeting) throws { try write(m, in: m.directory) }
    private func write(_ m: Meeting, in dir: URL) throws {
        let path = dir.appendingPathComponent("meeting.json")
        var existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any] ?? [:]
        let oldStatus = existing["status"] as? String
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(m)) as! [String: Any]
        for key in ["error", "capture_warning", "generate_mom", "error_kind", "retry_at", "codex_account_id", "failed_step"] { existing.removeValue(forKey: key) }
        existing.merge(encoded) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
        let newStatus = encoded["status"] as? String
        guard oldStatus != newStatus, let newStatus else { return }
        let event: String?
        switch newStatus {
        case "transcribed": event = "transcript.ready"
        case "complete": event = "notes.ready"
        case "failed", "waiting_for_limit": event = "processing.failed"
        default: event = nil
        }
        guard let event else { return }
        var details: [String: Any] = [:]
        if let step = encoded["failed_step"] as? String { details["step"] = step }
        if let kind = encoded["error_kind"] as? String { details["kind"] = kind }
        if let message = encoded["error"] as? String { details["message"] = message }
        if let retryAt = encoded["retry_at"] as? String { details["retry_at"] = retryAt }
        do { try MeetingHooks.enqueue(event: event, directory: dir, metadata: ["failure": details]) }
        catch { fputs("catet: could not queue \(event) hook: \(error)\n", stderr) }
    }
    func isProcessRunning(for meeting: Meeting) -> Bool {
        isMeetingLockHeld(meeting.id)
    }
    private func isMeetingLockHeld(_ meetingID: String) -> Bool {
        let lockURL = root.deletingLastPathComponent().appendingPathComponent("runtime/locks/\(meetingID).lock")
        let descriptor = open(lockURL.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { _ = catetFlock(descriptor, LOCK_UN); return false }
        return true
    }
    func isLocallyProcessing(_ meetingID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeProcessIDs.contains(meetingID) || reservedMeetingLocks[meetingID] != nil || isMeetingLockHeld(meetingID)
    }
    func runEngine(meeting: Meeting, command: String, transcriptOnly: Bool, accountID: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        let requestedAccountID: String?
        do {
            if command == "mom" || (command == "process" && !transcriptOnly) {
                let accounts = CodexAccounts(root: root)
                requestedAccountID = try accountID.map { try accounts.snapshot(id: $0).account.id } ?? accounts.selected().account.id
            } else { requestedAccountID = nil }
        } catch { completion(.failure(error)); return }
        lock.lock()
        guard !activeProcessIDs.contains(meeting.id), reservedMeetingLocks[meeting.id] == nil, !isProcessRunning(for: meeting) else {
            lock.unlock()
            completion(.failure(StoreError.processing("This meeting is already being processed or recorded.")))
            return
        }
        activeProcessIDs.insert(meeting.id)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                guard let executableURL = Bundle.main.executableURL else { throw StoreError.configuration("App executable location is unavailable.") }
                let engine = executableURL.deletingLastPathComponent().appendingPathComponent("CatetEngine")
                guard FileManager.default.isExecutableFile(atPath: engine.path) else { throw StoreError.configuration("CatetEngine is missing from the app bundle.") }
                let p = Process(); p.executableURL = engine
                var args = ["--root", self.root.path, command, meeting.directory.path]
                if command == "process" && !transcriptOnly { args.append("--mom") }
                p.arguments = args; p.currentDirectoryURL = meeting.directory
                if let requestedAccountID {
                    var environment = ProcessInfo.processInfo.environment
                    environment["CATET_CODEX_ACCOUNT_ID"] = requestedAccountID
                    p.environment = environment
                }
                let logURL = meeting.directory.appendingPathComponent("processing.log")
                try? FileManager.default.removeItem(at: logURL)
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: logURL)
                p.standardOutput = handle; p.standardError = handle
                self.lock.lock(); self.activeProcesses[meeting.id] = p; self.lock.unlock()
                p.terminationHandler = { [weak self] proc in
                    try? handle.close()
                    proc.terminationHandler = nil
                    self?.finishProcess(meetingID: meeting.id)
                    completion(proc.terminationStatus == 0 ? .success(()) : .failure(StoreError.processing("CatetEngine exited with status \(proc.terminationStatus). See processing.log.")))
                }
                try p.run()
            } catch {
                self.finishProcess(meetingID: meeting.id)
                completion(.failure(error))
            }
        }
    }
    private func finishProcess(meetingID: String) {
        lock.lock(); activeProcessIDs.remove(meetingID); activeProcesses.removeValue(forKey: meetingID); lock.unlock()
    }
}

enum StoreError: LocalizedError {
    case configuration(String), processing(String)
    var errorDescription: String? { switch self { case .configuration(let s), .processing(let s): return s } }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
