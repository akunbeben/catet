import AppKit

extension CatetController {
    var selectedCodexAccountLabel: String {
        codexAccounts.first { $0.id == selectedCodexAccountID }?.label ?? "Codex account"
    }

    func refreshCodexAccounts() {
        let now = Date()
        defer { lastAccountRefreshAt = now }
        do {
            let registry = CodexAccounts(root: store.root)
            let accounts = try registry.accounts()
            let selectedID = try registry.selected().account.id
            let cooldownExpired = accounts.contains { account in
                account.retryAt.map { $0 > lastAccountRefreshAt && $0 <= now } == true
            }
            if codexAccounts != accounts || cooldownExpired { codexAccounts = accounts }
            if selectedCodexAccountID != selectedID { selectedCodexAccountID = selectedID }
        } catch {
            fputs("catet: could not load Codex accounts: \(error.localizedDescription)\n", stderr)
        }
    }

    func openCodexAccounts() {
        do {
            if codexAccountsWindow == nil {
                guard let runtimeURL = Bundle.main.url(forResource: "runtime", withExtension: "json"),
                      let config = try JSONSerialization.jsonObject(with: Data(contentsOf: runtimeURL)) as? [String: Any],
                      let path = config["codex"] as? String, path.hasPrefix("/") else {
                    throw StoreError.configuration("Codex is not configured. Run Catet setup before adding an account.")
                }
                codexAccountsWindow = CodexAccountsWindow(root: store.root, codex: URL(fileURLWithPath: path)) { [weak self] in
                    self?.refreshCodexAccounts()
                }
            }
            codexAccountsWindow?.show()
        } catch { reportError(error) }
    }

    func selectCodexAccount(_ id: String) {
        do {
            try CodexAccounts(root: store.root).select(id: id)
            refreshCodexAccounts()
        } catch { reportError(error) }
    }

    func retryScheduledNotes(now: Date = Date()) {
        guard !isRetryingScheduledNotes else { return }
        var candidate: Meeting?
        var earliest = Date.distantFuture
        for meeting in meetings where meeting.status == "waiting_for_limit" {
            guard let date = meeting.retryDate, date <= now, date < earliest,
                  !store.isLocallyProcessing(meeting.id), !store.isProcessRunning(for: meeting) else { continue }
            candidate = meeting
            earliest = date
        }
        guard let meeting = candidate else { return }
        isRetryingScheduledNotes = true
        store.runEngine(meeting: meeting, command: "retry-notes", transcriptOnly: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRetryingScheduledNotes = false
                if case .failure = result,
                   let current = self.store.meeting(id: meeting.id),
                   current.status == "waiting_for_limit", current.retry_at == meeting.retry_at,
                   !self.store.isProcessRunning(for: current) {
                    do {
                        try self.store.update(id: current.id) {
                            $0.status = "failed"
                            $0.error_kind = "codex"
                            $0.error = "The scheduled retry could not start. Try creating notes again."
                            $0.retry_at = nil
                        }
                    } catch { fputs("catet: could not save the scheduled retry state: \(error.localizedDescription)\n", stderr) }
                }
                self.refresh()
            }
        }
    }

    func openDiagnostics(_ meeting: Meeting) {
        let name = meeting.failed_step == "mom" || meeting.isUsageLimited || meeting.error_kind == "codex" || meeting.error_kind == "authentication"
            ? "codex.stderr.log" : "processing.log"
        let log = meeting.directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else { openFolder(meeting) }
    }
}
