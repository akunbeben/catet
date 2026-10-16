import Foundation
import Darwin
import AVFoundation
@_silgen_name("flock")
func catetFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct Meeting: Identifiable, Codable {
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
        case "transcription": return "The recording could not be transcribed. Your audio is still saved."
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
    init() {
        if let path = ProcessInfo.processInfo.environment["CATET_MEETINGS_ROOT"], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Catet/meetings", isDirectory: true)
        }
    }
    func createRoot() throws { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
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
                if isLocallyProcessing(all[i].id) || isProcessRunning(for: all[i]) { continue }
                all[i].status = "recorded"
                if !fm.fileExists(atPath: all[i].directory.appendingPathComponent("microphone.wav").path) && !fm.fileExists(atPath: all[i].directory.appendingPathComponent("system.wav").path) {
                    all[i].error = "The app stopped before audio was finalized. No complete recording is available."
                } else { all[i].error = "Catet restarted during recording. Available audio was preserved; retry transcription to continue." }
                do { try persist(all[i]) } catch { all[i].error = "Could not save recovery state: \(error.localizedDescription)" }
            } else if status == "transcribing" || status == "summarizing" {
                if !isLocallyProcessing(all[i].id) && !isProcessRunning(for: all[i]) {
                    all[i].status = "failed"; all[i].error = "Processing stopped before it completed. Retry the action to continue."
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
    func saveRecording(id: String, failure: String?) throws {
        try update(id: id) {
            $0.status = failure == nil ? "recorded" : "failed"
            $0.error = failure
        }
    }
    func recordingDuration(for meeting: Meeting) -> TimeInterval? {
        ["microphone.wav", "system.wav"].compactMap { name -> TimeInterval? in
            guard let audio = try? AVAudioFile(forReading: meeting.directory.appendingPathComponent(name)),
                  audio.processingFormat.sampleRate > 0 else { return nil }
            return Double(audio.length) / audio.processingFormat.sampleRate
        }.max()
    }

    @discardableResult
    func discardRecording(id: String) throws -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard !activeProcessIDs.contains(id), let meeting = loadAll().first(where: { $0.id == id }),
              meeting.status == "recorded" else {
            throw StoreError.processing("Only a saved, unprocessed recording can be moved to Trash.")
        }
        let directory = meeting.directory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.lastPathComponent == id,
              directory.deletingLastPathComponent() == root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw StoreError.configuration("The recording is outside the meeting library.")
        }
        let locks = root.deletingLastPathComponent().appendingPathComponent("runtime/locks", isDirectory: true)
        try fm.createDirectory(at: locks, withIntermediateDirectories: true)
        let descriptor = open(locks.appendingPathComponent("\(id).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.processing("Could not check whether the recording is in use.") }
        defer { close(descriptor) }
        guard catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw StoreError.processing("This recording is still in use. Stop recording or processing before discarding it.")
        }
        defer { _ = catetFlock(descriptor, LOCK_UN) }
        let current = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
        guard current.id == id, current.status == "recorded" else {
            throw StoreError.processing("The recording changed before it could be discarded. It was kept.")
        }
        var trashedURL: NSURL?
        try fm.trashItem(at: directory, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }
    private func persist(_ m: Meeting) throws { try write(m, in: m.directory) }
    private func write(_ m: Meeting, in dir: URL) throws {
        let path = dir.appendingPathComponent("meeting.json")
        var existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any] ?? [:]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(m)) as! [String: Any]
        for key in ["error", "capture_warning", "generate_mom", "error_kind", "retry_at", "codex_account_id", "failed_step"] { existing.removeValue(forKey: key) }
        existing.merge(encoded) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }
    func isProcessRunning(for meeting: Meeting) -> Bool {
        let lockURL = root.deletingLastPathComponent().appendingPathComponent("runtime/locks/\(meeting.id).lock")
        let descriptor = open(lockURL.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if catetFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { _ = catetFlock(descriptor, LOCK_UN); return false }
        return true
    }
    func isLocallyProcessing(_ meetingID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeProcessIDs.contains(meetingID)
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
        guard !activeProcessIDs.contains(meeting.id), !isProcessRunning(for: meeting) else {
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
