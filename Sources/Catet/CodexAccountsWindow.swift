import AppKit
import Darwin
import Foundation

@_silgen_name("flock")
private func codetWindowFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private final class CodexAccountsDocument: NSView {
    override var isFlipped: Bool { true }
}

final class CodexAccountsWindow: NSObject, NSWindowDelegate {
    private let root: URL
    private let codex: URL
    private let didChange: () -> Void
    private let accounts: CodexAccounts
    private let window: NSWindow
    private let list = NSStackView()
    private let scrollView = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var loginProcess: Process?
    private var loginAccountID: String?
    private var accountLockDescriptor: Int32 = -1
    private var isVerifyingLogin = false
    private var transientStatus: [String: String] = [:]

    init(root: URL, codex: URL, didChange: @escaping () -> Void) {
        self.root = root
        self.codex = codex
        self.didChange = didChange
        accounts = CodexAccounts(root: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Codex Accounts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let document = CodexAccountsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        document.addSubview(list)
        message.maximumNumberOfLines = 0
        message.textColor = .secondaryLabelColor
        let add = NSButton(title: "Add Account", target: self, action: #selector(addAccount))
        let content = NSView()
        let stack = NSStackView(views: [scrollView, add, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.center()
        refresh()
    }

    func show() {
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { cancelLogin() }

    @objc private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "Add a Codex account"
        alert.informativeText = "Choose a name, then sign in in your browser."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Account name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try accounts.add(label: field.stringValue)
            message.stringValue = "Account added. Sign in to make it available."
            refresh()
        } catch { showError(error) }
    }

    private func refresh() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        do {
            let selected = (try? accounts.selected())?.account.id
            let models = try accounts.accounts()
            for account in models {
                let title = NSTextField(labelWithString: account.label)
                title.font = .boldSystemFont(ofSize: 13)
                let status: String
                if account.id == "default" { status = "Uses the account signed in through Terminal." }
                else if let note = transientStatus[account.id] { status = note }
                else { status = account.isAuthenticated ? "Signed in" : "Not signed in" }
                let detail = NSTextField(wrappingLabelWithString: status)
                detail.textColor = .secondaryLabelColor
                let select = NSButton(title: selected == account.id ? "Selected" : "Select", target: self, action: #selector(selectAccount(_:)))
                select.identifier = NSUserInterfaceItemIdentifier(account.id)
                select.isEnabled = selected != account.id && (account.id == "default" || account.isAuthenticated) && loginAccountID == nil
                let labels = NSStackView(views: [title, detail])
                labels.orientation = .vertical
                labels.alignment = .leading
                labels.spacing = 3
                let row = NSStackView(views: [labels, select])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 10
                row.distribution = .fill
                if account.id != "default" {
                    let loginTitle = loginAccountID == account.id ? (isVerifyingLogin ? "Checking Sign In…" : "Cancel Sign In") : (account.isAuthenticated ? "Sign In Again" : "Sign In")
                    let signIn = NSButton(title: loginTitle, target: self, action: #selector(signInOrCancel(_:)))
                    signIn.identifier = NSUserInterfaceItemIdentifier(account.id)
                    signIn.isEnabled = loginAccountID == nil || (loginAccountID == account.id && loginProcess != nil)
                    row.addArrangedSubview(signIn)
                }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
                detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
        } catch { message.stringValue = error.localizedDescription }
    }

    @objc private func selectAccount(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try accounts.select(id: id)
            message.stringValue = "New requests will use this account."
            didChange()
            refresh()
        } catch { showError(error) }
    }

    @objc private func signInOrCancel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if loginAccountID == id, loginProcess != nil { cancelLogin(); return }
        guard loginAccountID == nil else { return }
        startLogin(id: id)
    }

    private func startLogin(id: String) {
        do {
            let snapshot = try accountForLogin(id: id)
            guard let home = snapshot.home else { throw CodexAccountsError.unknownAccount }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            accountLockDescriptor = try acquireAccountLock(id: id)
            do { try accounts.setAuthenticated(false, for: id) }
            catch { releaseAccountLock(); throw error }
            transientStatus[id] = "Waiting for browser sign-in…"
            isVerifyingLogin = false
            let process = Process()
            process.executableURL = codex
            process.arguments = ["--no-daemon", "-c", "cli_auth_credentials_store=\"file\"", "login"]
            process.environment = codexAccountEnvironment(base: ProcessInfo.processInfo.environment, snapshot: snapshot)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            loginProcess = process
            loginAccountID = id
            process.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self, self.loginProcess === finished, self.loginAccountID == id else { return }
                    self.loginProcess = nil
                    guard finished.terminationReason == .exit, finished.terminationStatus == 0 else {
                        self.loginAccountID = nil
                        self.releaseAccountLock()
                        self.transientStatus[id] = "Sign-in failed. Try again."
                        self.refresh()
                        return
                    }
                    self.verifyLogin(id: id, snapshot: snapshot)
                }
            }
            do {
                try process.run()
                scheduleTimeout(process, id: id, after: 600, message: "Sign-in took too long. Try again.")
            } catch {
                loginProcess = nil
                loginAccountID = nil
                releaseAccountLock()
                transientStatus[id] = "Could not start sign-in. Check that Codex is available."
                refresh()
            }
            refresh()
        } catch { showError(error) }
    }

    private func acquireAccountLock(id: String) throws -> Int32 {
        let url = codexAccountLockURL(root: root, accountID: id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        } catch { throw CodexAccountsError.storage("Could not prepare account sign-in.") }
        let descriptor = url.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
        guard descriptor >= 0 else { throw CodexAccountsError.storage("Could not open the account sign-in lock.") }
        _ = fchmod(descriptor, mode_t(0o600))
        guard codetWindowFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw CodexAccountsError.storage("This account is processing a request. Try again later.")
        }
        return descriptor
    }

    private func releaseAccountLock() {
        guard accountLockDescriptor >= 0 else { return }
        _ = codetWindowFlock(accountLockDescriptor, LOCK_UN)
        _ = Darwin.close(accountLockDescriptor)
        accountLockDescriptor = -1
    }

    private func scheduleTimeout(_ process: Process, id: String, after seconds: TimeInterval, message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.loginAccountID == id, self.loginProcess === process else { return }
            process.terminationHandler = nil
            self.loginProcess = nil
            self.loginAccountID = nil
            self.isVerifyingLogin = false
            self.stopProcessAndReleaseLock(process)
            self.transientStatus[id] = message
            self.refresh()
        }
    }
    private func stopProcessAndReleaseLock(_ process: Process) {
        let descriptor = accountLockDescriptor
        accountLockDescriptor = -1
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if descriptor >= 0 {
                _ = codetWindowFlock(descriptor, LOCK_UN)
                _ = Darwin.close(descriptor)
            }
        }
    }


    private func accountForLogin(id: String) throws -> CodexAccountSnapshot {
        // Login must remain possible when the isolated account has not authenticated yet.
        let model = try accounts.accounts().first(where: { $0.id == id })
        guard let model, id != "default" else { throw CodexAccountsError.unknownAccount }
        return CodexAccountSnapshot(account: model, home: root.deletingLastPathComponent().appendingPathComponent("runtime/codex-accounts/homes", isDirectory: true).appendingPathComponent(id, isDirectory: true))
    }

    private func verifyLogin(id: String, snapshot: CodexAccountSnapshot) {
        let process = Process()
        process.executableURL = codex
        process.arguments = ["--no-daemon", "-c", "cli_auth_credentials_store=\"file\"", "login", "status"]
        process.environment = codexAccountEnvironment(base: ProcessInfo.processInfo.environment, snapshot: snapshot)
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            loginProcess = process
            isVerifyingLogin = true
            scheduleTimeout(process, id: id, after: 30, message: "Could not verify sign-in. Try again.")
            DispatchQueue.global(qos: .utility).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                let valid = process.terminationReason == .exit && process.terminationStatus == 0 && text.contains("chatgpt") && (text.contains("logged in") || text.contains("authenticated"))
                DispatchQueue.main.async {
                    guard self.loginAccountID == id, self.loginProcess === process else { return }
                    self.loginProcess = nil
                    self.isVerifyingLogin = false
                    if valid {
                        do {
                            try self.secureAccountHome(snapshot.home)
                            try self.accounts.setAuthenticated(true, for: id)
                            self.transientStatus[id] = "Sign-in complete."
                            self.didChange()
                        } catch { self.transientStatus[id] = "Sign-in could not be saved. Try again." }
                    } else {
                        self.transientStatus[id] = "Sign in with ChatGPT to use this account."
                    }
                    self.loginAccountID = nil
                    self.releaseAccountLock()
                    self.refresh()
                }
            }
        } catch {
            loginProcess = nil
            loginAccountID = nil
            isVerifyingLogin = false
            releaseAccountLock()
            transientStatus[id] = "Could not verify sign-in. Check that Codex is available."
            refresh()
        }
    }
    private func secureAccountHome(_ home: URL?) throws {
        guard let home else { return }
        let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } else if values.isRegularFile == true {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }


    private func cancelLogin() {
        guard let process = loginProcess, let id = loginAccountID else { return }
        process.terminationHandler = nil
        loginProcess = nil
        loginAccountID = nil
        isVerifyingLogin = false
        stopProcessAndReleaseLock(process)
        transientStatus[id] = "Sign-in was cancelled."
        refresh()
    }

    private func showError(_ error: Error) {
        message.stringValue = error.localizedDescription
        refresh()
    }
}
