import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers
import QuartzCore

@main
struct CatetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CatetController!
    private var statusItem: NSStatusItem!
    private var permissionsWindow: PermissionsWindow!
    private var quickRecordingShortcut: QuickRecordingShortcut?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = CatetBrand.applicationIcon
        controller = CatetController()
        controller.startup()
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuIcon = CatetBrand.mark.copy() as? NSImage
        menuIcon?.size = NSSize(width: 18, height: 18)
        menuIcon?.isTemplate = true
        statusItem.button?.image = menuIcon
        statusItem.button?.setAccessibilityLabel("Catet")
        statusItem.button?.toolTip = "Catet meeting notes"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Meeting Library", action: #selector(openLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "New Recording", action: #selector(newRecording), keyEquivalent: "")
        menu.addItem(withTitle: "Quick Recording", action: #selector(toggleQuickRecording), keyEquivalent: "")
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Catet", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        permissionsWindow = PermissionsWindow()
        permissionsWindow.onOpenCodexAccounts = { [weak self] in self?.controller.openCodexAccounts() }
        do {
            quickRecordingShortcut = try QuickRecordingShortcut { [weak self] in self?.controller.toggleQuickRecordingKeyboard() }
            controller.quickRecordingShortcutAvailable = true
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Quick recording shortcut unavailable"
                alert.informativeText = "\(error.localizedDescription) You can still open Quick Recording with ⇧⌘R while Catet is active."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        controller.showLibrary()
        if CommandLine.arguments.contains("--request-system-audio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.permissionsWindow.requestSystemAudioOnLaunch()
                self?.permissionsWindow.show()
            }
        } else if CommandLine.arguments.contains("--permissions") {
            DispatchQueue.main.async { [weak self] in self?.permissionsWindow.show() }
        }
    }
    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Catet", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openPermissions), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Codex Accounts…", action: #selector(openCodexAccounts), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Catet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Catet", action: #selector(quit), keyEquivalent: "q")
        appMenu.items.forEach { $0.target = self }
        appMenu.item(withTitle: "Hide Catet")?.target = NSApp
        app.submenu = appMenu
        main.addItem(app)

        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Recording", action: #selector(newRecording), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Import Audio…", action: #selector(importMeetingAudio), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        let quick = fileMenu.addItem(withTitle: "Quick Recording", action: #selector(toggleQuickRecording), keyEquivalent: "r")
        quick.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Meeting Library", action: #selector(openLibrary), keyEquivalent: "0")
        fileMenu.items.forEach { $0.target = self }
        file.submenu = fileMenu
        main.addItem(file)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.items.forEach { $0.target = nil }
        edit.submenu = editMenu
        main.addItem(edit)

        let window = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.items.forEach { $0.target = nil }
        window.submenu = windowMenu
        main.addItem(window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
    func applicationDidBecomeActive(_ notification: Notification) { permissionsWindow?.applicationDidBecomeActive() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showLibrary()
        return false
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "catet" && $0.host == "permissions" }) {
            permissionsWindow.show()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.isRecording {
            let alert = NSAlert(); alert.messageText = "Save this recording before quitting?"
            alert.informativeText = "Catet will stop and save the audio files before it quits."
            alert.addButton(withTitle: "Save and Quit"); alert.addButton(withTitle: "Keep Catet Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            controller.quitAfterRecordingStops = true
            controller.stopRecording()
            return .terminateLater
        }
        if controller.runningMeetingCount > 0 {
            let alert = NSAlert(); alert.messageText = "Processing is still running"
            alert.informativeText = "Quitting will not stop the processing jobs, but their results may not appear until Catet is reopened."
            alert.addButton(withTitle: "Quit Anyway"); alert.addButton(withTitle: "Keep Catet Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        return .terminateNow
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationIcon: CatetBrand.applicationIcon])
    }
    @objc private func openPermissions() { permissionsWindow.show() }
    @objc private func openCodexAccounts() { controller.openCodexAccounts() }
    @objc private func openLibrary() { controller.showLibrary() }
    @objc private func newRecording() { controller.beginRecordingFlow() }
    @objc private func importMeetingAudio() { controller.importAudio() }
    @objc private func toggleQuickRecording() { controller.toggleQuickRecordingKeyboard() }
    @objc private func quit() { NSApp.terminate(nil) }
}

final class CatetController: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var currentRecordingID: String?
    @Published var recordingStartedAt: Date?
    var isRecording: Bool { currentRecordingID != nil }
    @Published var micAvailable = false
    @Published var systemAudioAvailable = false
    @Published var statusMessage = ""
    @Published var quickRecordingKeyboardActive = false
    @Published var quickRecordingShortcutAvailable = false
    @Published var codexAccounts: [CodexAccount] = []
    @Published var selectedCodexAccountID = "default"
    var codexAccountsWindow: CodexAccountsWindow?
    var isRetryingScheduledNotes = false
    let store = MeetingStore()
    let recorder = MeetingRecorder()
    private var libraryWindow: NSWindow?
    private var pillWindow: NSWindow?
    private var refreshTimer: Timer?
    var recordingFailure: String?
    var isStoppingRecording = false
    var recordingReady = false
    var pendingRecordingStop = false
    var quitAfterRecordingStops = false
    var runningMeetingCount: Int { meetings.filter { store.isLocallyProcessing($0.id) || store.isProcessRunning(for: $0) }.count }
    var didOfferMicOnly = false
    var processAfterRecordingStops = true

    func startup() {
        do { try store.createRoot() } catch { reportError(error) }
        meetings = store.loadAndRecover()
        refreshCodexAccounts()
        recorder.onState = { [weak self] mic, system, message in
            guard let self, self.isRecording, !self.isStoppingRecording else { return }
            self.micAvailable = mic; self.systemAudioAvailable = system; self.statusMessage = message
            if mic && self.recordingStartedAt == nil { self.recordingStartedAt = Date() }
        }
        recorder.onIssue = { [weak self] issue in
            guard let self, let id = self.currentRecordingID, !self.isStoppingRecording else { return }
            if issue.source == .microphone {
                self.recordingFailure = issue.error.localizedDescription
                self.stopRecording()
            } else {
                do { try self.store.update(id: id) { $0.capture_warning = issue.warning } }
                catch { self.reportError(error) }
                self.refresh()
                if !self.didOfferMicOnly {
                    self.didOfferMicOnly = true
                    self.offerMicOnlyChoice(issue)
                }
            }
        }
        makePill()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        meetings = store.loadAndRecover()
        refreshCodexAccounts()
        retryScheduledNotes()
    }
    func reportError(_ error: Error) {
        statusMessage = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "Catet could not complete this action"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    func offerMicOnlyChoice(_ issue: CaptureIssue) {
        let alert = SystemAudioRecoveryDialog(issue: issue).alert
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            statusMessage = issue.warning
        } else {
            processAfterRecordingStops = false
            stopRecording()
            if choice == .alertThirdButtonReturn { openAudioSettings() }
        }
    }
    func openAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func showLibrary() {
        if let libraryWindow, libraryWindow.isVisible { libraryWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = LibraryView(controller: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Catet Meetings"; window.setContentSize(NSSize(width: 880, height: 650)); window.minSize = NSSize(width: 650, height: 460)
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); libraryWindow = window
    }
    private func makePill() {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: FloatingPill.collapsedWidth, height: FloatingPill.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: FloatingPill(controller: self))
        content.sizingOptions = []
        panel.contentView = content
        panel.onKeyboardEvent = { [weak self] event in self?.handleQuickRecordingKey(event) ?? false }
        panel.onKeyboardDismiss = { [weak self] in self?.dismissQuickRecordingKeyboard() }
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 2, y: screen.visibleFrame.midY - FloatingPill.height / 2))
        }
        panel.orderFrontRegardless(); pillWindow = panel
    }
    func setPillExpanded(_ expanded: Bool) {
        guard let panel = pillWindow, let screen = panel.screen ?? NSScreen.main else { return }
        let width = expanded || quickRecordingKeyboardActive ? FloatingPill.expandedWidth : FloatingPill.collapsedWidth
        let height = FloatingPill.height + (quickRecordingKeyboardActive ? FloatingPill.keyboardHintHeight : 0)
        let target = NSRect(x: screen.visibleFrame.minX + 2, y: panel.frame.minY, width: width, height: height)
        guard panel.frame != target else { return }
        if quickRecordingKeyboardActive || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FloatingPill.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }
    func toggleQuickRecordingKeyboard() {
        guard NSApp.modalWindow == nil, let panel = pillWindow as? FloatingPanel else { return }
        if quickRecordingKeyboardActive && panel.isKeyWindow {
            dismissQuickRecordingKeyboard()
            return
        }
        quickRecordingKeyboardActive = true
        panel.keyboardEnabled = true
        setPillExpanded(true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    func dismissQuickRecordingKeyboard() {
        guard quickRecordingKeyboardActive else { return }
        quickRecordingKeyboardActive = false
        if let panel = pillWindow as? FloatingPanel {
            panel.keyboardEnabled = false
            if panel.isKeyWindow { panel.resignKey() }
        }
        setPillExpanded(isRecording)
    }

    private func handleQuickRecordingKey(_ event: NSEvent) -> Bool {
        guard quickRecordingKeyboardActive, NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers == .command {
                dismissQuickRecordingKeyboard()
                showLibrary()
                return true
            }
            guard modifiers.isEmpty else { return false }
            if !event.isARepeat && !isStoppingRecording {
                if isRecording { stopRecording() } else { beginRecordingFlow() }
            }
            return true
        }
        if event.keyCode == 53 && modifiers.isEmpty {
            dismissQuickRecordingKeyboard()
            return true
        }
        return false
    }
    func stopRecording() {
        guard !isStoppingRecording, let id = currentRecordingID, let meeting = store.meeting(id: id) else { return }
        guard recordingReady else { pendingRecordingStop = true; return }
        isStoppingRecording = true
        recorder.stop { [weak self] result in
            guard let self else { return }
            var failure = self.recordingFailure
            if case .failure(let error) = result { failure = error.localizedDescription }
            do {
                try self.store.saveRecording(id: id, failure: failure)
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.currentRecordingID = nil; self.recordingStartedAt = nil
                self.micAvailable = false; self.systemAudioAvailable = false
                self.isStoppingRecording = false; self.recordingFailure = nil
                self.recordingReady = false; self.pendingRecordingStop = false; self.refresh()
                if let failure { self.reportError(StoreError.processing(failure)) }
                else if self.keepShortRecording(meeting), !self.quitAfterRecordingStops && self.processAfterRecordingStops {
                    self.process(meeting, mom: meeting.generate_mom == true)
                }
                if self.quitAfterRecordingStops { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
    }
    private func keepShortRecording(_ meeting: Meeting) -> Bool {
        guard let dialog = ShortRecordingDialog(duration: store.recordingDuration(for: meeting)) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.alert.runModal() == .alertSecondButtonReturn else { return true }
        do {
            try store.discardRecording(id: meeting.id)
            refresh()
        } catch {
            reportError(error)
        }
        return false
    }
    func process(_ meeting: Meeting, mom: Bool) {
        guard !store.isLocallyProcessing(meeting.id), !store.isProcessRunning(for: meeting) else { return }
        store.runEngine(meeting: meeting, command: "process", transcriptOnly: !mom) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyEngineResult(result, to: meeting)
            }
        }
    }
    func createMoM(_ meeting: Meeting, accountID: String? = nil) {
        guard FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("transcript.txt").path),
              !store.isLocallyProcessing(meeting.id), !store.isProcessRunning(for: meeting) else { return }
        let account: CodexAccountSnapshot
        do {
            let accounts = CodexAccounts(root: store.root)
            account = try accountID.map { try accounts.snapshot(id: $0) } ?? accounts.selected()
        } catch { reportError(error); return }
        if let retryAt = account.account.retryAt, retryAt > Date() {
            let alert = NSAlert()
            alert.messageText = "This account is waiting for its limit to reset"
            alert.informativeText = "Try after \(retryAt.formatted(date: .abbreviated, time: .shortened)), or choose another Codex account."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let alert = NSAlert(); alert.messageText = "Create meeting notes?"
        alert.informativeText = "Your transcript will be sent to Codex using \(account.account.label) to create meeting notes and a title. Audio stays on your Mac."
        alert.addButton(withTitle: "Create notes"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try CodexAccounts(root: store.root).select(id: account.account.id) }
        catch { reportError(error); return }
        refreshCodexAccounts()
        store.runEngine(meeting: meeting, command: "mom", transcriptOnly: false, accountID: account.account.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyEngineResult(result, to: meeting)
            }
        }
    }
    func applyEngineResult(_ result: Result<Void, Error>, to meeting: Meeting) {
        if case .failure(let error) = result {
            if error.localizedDescription.contains("already being processed or recorded") { return }
            do {
                try store.update(id: meeting.id) {
                    if $0.status == "waiting_for_limit" { return }
                    if $0.status != "failed" {
                        $0.status = "failed"
                        $0.error = "Processing could not finish. Your saved files are still available."
                        $0.error_kind = "codex"
                    } else if $0.error == nil {
                        $0.error = "Processing could not finish. Open diagnostics for details."
                    }
                }
            } catch { reportError(error) }
        }
        refresh()
    }
    func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let meeting = try store.newMeeting(title: url.deletingPathExtension().lastPathComponent)
                do {
                    let destination = meeting.directory.appendingPathComponent("input.\(url.pathExtension.lowercased())")
                    try FileManager.default.copyItem(at: url, to: destination)
                    try store.update(id: meeting.id) { $0.status = "recorded" }
                    store.runEngine(meeting: meeting, command: "process", transcriptOnly: true) { [weak self] result in
                        DispatchQueue.main.async { guard let self else { return }; self.applyEngineResult(result, to: meeting) }
                    }
                } catch {
                    try store.update(id: meeting.id) { $0.status = "failed"; $0.error = error.localizedDescription }
                    reportError(error)
                }
            } catch { reportError(error) }
        }
        refresh()
    }
    func retryTranscription(_ meeting: Meeting) { process(meeting, mom: false) }
    func openFolder(_ meeting: Meeting) { NSWorkspace.shared.open(meeting.directory) }
}

extension DateFormatter {
    static var catet: DateFormatter { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }
}

final class FloatingPanel: NSPanel {
    var keyboardEnabled = false
    var onKeyboardEvent: ((NSEvent) -> Bool)?
    var onKeyboardDismiss: (() -> Void)?
    override var canBecomeKey: Bool { keyboardEnabled }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if keyboardEnabled, event.type == .keyDown, onKeyboardEvent?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        if keyboardEnabled { onKeyboardDismiss?() }
    }
}
