import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers
import QuartzCore

@main
struct CatetApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
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
        if controller.hasActiveRecordingLifecycle {
            let alert = NSAlert(); alert.messageText = "Save this recording before quitting?"
            alert.informativeText = "Catet will stop the recording and finish transcription before it quits."
            alert.addButton(withTitle: "Save and Quit"); alert.addButton(withTitle: "Keep Catet Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            controller.quitAfterRecordingStops = true
            if controller.isRecording { controller.stopRecording() }
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

@MainActor
final class CatetController: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var currentRecordingID: String?
    @Published var recordingStartedAt: Date?
    var isRecording: Bool { currentRecordingID != nil && !isStoppingRecording }
    var hasActiveRecordingLifecycle: Bool { currentRecordingID != nil }
    @Published var micAvailable = false
    @Published var systemAudioAvailable = false
    @Published var liveTranscriptionStatusMessage = ""
    @Published var quickRecordingKeyboardActive = false
    @Published var quickRecordingShortcutAvailable = false
    @Published private(set) var pillExpanded = false
    @Published var codexAccounts: [CodexAccount] = []
    @Published var selectedCodexAccountID = "default"
    var codexAccountsWindow: CodexAccountsWindow?
    var isRetryingScheduledNotes = false
    var lastAccountRefreshAt = Date.distantPast
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
    private var liveTranscription: LiveTranscription?
    private var liveTranscriptionMeetingID: String?
    private var liveTranscriptionStartTask: Task<Void, Never>?
    private var liveTranscriptionMonitorTask: Task<Void, Never>?
    private let hookQueue = DispatchQueue(label: "catet.hooks.delivery", qos: .utility)
    private func drainHooks() {
        let root = store.root
        hookQueue.async {
            do { try MeetingHooks.deliverPending(root: root) }
            catch { fputs("catet: could not deliver command hooks: \(error)\n", stderr) }
        }
    }
    func startup() {
        do { try store.createRoot() } catch { reportError(error) }
        meetings = store.loadAndRecover()
        drainHooks()
        refreshCodexAccounts()
        recorder.onState = { [weak self] mic, system in
            guard let self, self.isRecording, !self.isStoppingRecording else { return }
            self.micAvailable = mic; self.systemAudioAvailable = system
            if mic {
                if self.recordingStartedAt == nil { self.recordingStartedAt = Date() }
                if let id = self.currentRecordingID { self.startLiveTranscription(for: id) }
            }
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
        retryScheduledNotes()
        scheduleRefresh()
    }
    private func startLiveTranscription(for meetingID: String) {
        guard liveTranscriptionMeetingID == nil else { return }
        guard let meeting = store.meeting(id: meetingID), currentRecordingID == meetingID else { return }
        let session = LiveTranscription(directory: meeting.directory)
        liveTranscription = session
        liveTranscriptionMeetingID = meetingID
        let startTask = Task { await session.start() }
        liveTranscriptionStartTask = startTask
        liveTranscriptionStatusMessage = "Starting transcription"
        liveTranscriptionMonitorTask = Task { [weak self] in
            await startTask.value
            while !Task.isCancelled {
                let status = await session.status
                let message: String
                switch status {
                case .idle: message = "Starting transcription"
                case .preparingModel: message = "Preparing transcription model"
                case .transcribing: message = "Transcribing live audio"
                case .ready: message = "Listening for speech"
                case .failed(_): message = "Live transcription paused. Catet will transcribe after recording stops."
                case .cancelled: message = ""
                }
                DispatchQueue.main.async {
                    guard let self, self.liveTranscriptionMeetingID == meetingID else { return }
                    self.liveTranscriptionStatusMessage = message
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
    func refresh() {
        let updated = store.loadAndRecover()
        if meetings != updated { meetings = updated }
        drainHooks()
        refreshCodexAccounts()
        retryScheduledNotes()
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let showingProgress = libraryWindow?.isVisible == true || isRetryingScheduledNotes
            || meetings.contains { $0.status == "transcribing" || $0.status == "summarizing" }
        var interval: TimeInterval = showingProgress ? 1.5 : 15
        let now = Date()
        for meeting in meetings where meeting.status == "waiting_for_limit" {
            if let retry = meeting.retryDate, retry > now {
                interval = min(interval, retry.timeIntervalSince(now))
            }
        }
        let timer = Timer(timeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = min(interval * 0.1, 0.5)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
    func reportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Catet could not complete this action"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    func offerMicOnlyChoice(_ issue: CaptureIssue) {
        let alert = SystemAudioRecoveryDialog(issue: issue).alert
        let choice = alert.runModal()
        if choice != .alertFirstButtonReturn {
            processAfterRecordingStops = false
            stopRecording()
            if choice == .alertThirdButtonReturn { openAudioSettings() }
        }
    }
    func openAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func showLibrary() {
        if let libraryWindow, libraryWindow.isVisible { libraryWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh(); return }
        let view = LibraryView(controller: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Catet Meetings"; window.setContentSize(NSSize(width: 880, height: 650)); window.minSize = NSSize(width: 650, height: 460)
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); libraryWindow = window
        refresh()
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
        if pillExpanded != expanded { pillExpanded = expanded }
        guard let panel = pillWindow, let screen = panel.screen ?? NSScreen.main else { return }
        let width = expanded ? FloatingPill.expandedWidth : FloatingPill.collapsedWidth
        let height = FloatingPill.height + (expanded && quickRecordingKeyboardActive ? FloatingPill.keyboardHintHeight : 0)
        let target = NSRect(x: screen.visibleFrame.minX + 2, y: panel.frame.maxY - height, width: width, height: height)
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
        setPillExpanded(pillExpanded)
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
        do {
            try store.update(id: id) {
                $0.status = "transcribing"; $0.error = nil; $0.error_kind = nil; $0.failed_step = nil; $0.retry_at = nil
            }
        } catch { recordingFailure = error.localizedDescription }
        refresh()
        recorder.stop { [weak self] result in
            guard let self, self.currentRecordingID == id else { return }
            var failure = self.recordingFailure
            if case .failure(let error) = result { failure = error.localizedDescription }
            self.recordingFailure = nil
            DispatchQueue.main.async {
                self.recordingStartedAt = nil
                self.micAvailable = false; self.systemAudioAvailable = false
                self.recordingReady = false; self.pendingRecordingStop = false
                if failure == nil && !self.quitAfterRecordingStops && !self.keepShortRecording(meeting) {
                    self.discardRecording(meeting)
                    return
                }
                if failure == nil {
                    do {
                        try MeetingHooks.enqueue(event: "recording.saved", directory: meeting.directory, metadata: [:])
                        self.drainHooks()
                    } catch { fputs("catet: could not queue recording.saved hook: \(error)\n", stderr) }
                }
                self.finishRecording(meeting, captureFailure: failure)
            }
        }
    }
    private func keepShortRecording(_ meeting: Meeting) -> Bool {
        guard let dialog = ShortRecordingDialog(duration: store.recordingDuration(for: meeting)) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        return dialog.alert.runModal() != .alertSecondButtonReturn
    }
    private func finishRecording(_ meeting: Meeting, captureFailure: String?) {
        let id = meeting.id
        let session = liveTranscriptionMeetingID == id ? liveTranscription : nil
        let startTask = liveTranscriptionMeetingID == id ? liveTranscriptionStartTask : nil
        let store = self.store
        Task {
            await startTask?.value
            if let captureFailure {
                await session?.cancel()
                var failureForUser = captureFailure
                do {
                    try store.update(id: id) {
                        $0.status = "failed"; $0.error = captureFailure; $0.error_kind = nil
                        $0.failed_step = nil; $0.retry_at = nil
                    }
                } catch {
                    failureForUser = "Catet could not save the failure state for this recording. Your audio is still saved. \(error.localizedDescription)"
                }
                store.releaseLiveTranscriptionReservation(id)
                DispatchQueue.main.async { self.completeRecordingLifecycle(meeting, failure: StoreError.processing(failureForUser)) }
                return
            }
            liveTranscriptionMonitorTask?.cancel()
            liveTranscriptionMonitorTask = nil
            liveTranscriptionStatusMessage = "Finishing transcript"
            do {
                try await store.finishTranscription(meeting: meeting, finishLive: {
                    guard let session else {
                        throw StoreError.processing("Live transcription did not start.")
                    }
                    try await session.finish()
                }, cancelLive: {
                    self.liveTranscriptionStatusMessage = "Transcribing saved audio"
                    await session?.cancel()
                })
            } catch {
                var failureForUser = "The recording could not be transcribed. Your audio is still saved. Choose Retry transcription to try again."
                do {
                    try store.update(id: id) {
                        // Preserve the engine's final failure and diagnostic details.
                        guard $0.status != "failed" else { return }
                        $0.status = "failed"; $0.error = error.localizedDescription
                        $0.error_kind = "transcription"; $0.failed_step = "transcribe"; $0.retry_at = nil
                    }
                } catch {
                    failureForUser = "Catet could not save the transcription state. Your audio is still saved. \(error.localizedDescription)"
                }
                self.completeRecordingLifecycle(meeting, failure: StoreError.processing(failureForUser))
                return
            }
            self.completeRecordingLifecycle(meeting, failure: nil)
        }
    }
    private func discardRecording(_ meeting: Meeting) {
        let id = meeting.id
        let session = liveTranscriptionMeetingID == id ? liveTranscription : nil
        let startTask = liveTranscriptionMeetingID == id ? liveTranscriptionStartTask : nil
        let store = self.store
        Task {
            await startTask?.value
            await session?.cancel()
            var failure: Error?
            do {
                try store.update(id: id) {
                    $0.status = "recorded"; $0.error = nil; $0.error_kind = nil
                    $0.failed_step = nil; $0.retry_at = nil
                }
            } catch { failure = error }
            store.releaseLiveTranscriptionReservation(id)
            DispatchQueue.main.async {
                self.clearLiveTranscription(for: id)
                if let failure { self.reportError(failure) }
                else {
                    do { try store.moveToTrash(ids: [id], onlyUnprocessedRecordings: true) }
                    catch { self.reportError(error) }
                }
                self.completeRecordingUI()
                self.replyToQuitIfNeeded()
            }
        }
    }
    private func completeRecordingLifecycle(_ meeting: Meeting, failure: Error?) {
        clearLiveTranscription(for: meeting.id)
        completeRecordingUI()
        if let failure {
            if !quitAfterRecordingStops { reportError(failure) }
        } else if processAfterRecordingStops && !quitAfterRecordingStops {
            process(meeting, mom: meeting.generate_mom == true)
        }
        replyToQuitIfNeeded()
    }
    private func replyToQuitIfNeeded() {
        guard quitAfterRecordingStops else { return }
        quitAfterRecordingStops = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    private func completeRecordingUI() {
        currentRecordingID = nil; recordingStartedAt = nil
        micAvailable = false; systemAudioAvailable = false
        isStoppingRecording = false; recordingFailure = nil
        recordingReady = false; pendingRecordingStop = false
        refresh()
    }
    private func clearLiveTranscription(for meetingID: String) {
        guard liveTranscriptionMeetingID == meetingID else { return }
        liveTranscriptionMonitorTask?.cancel(); liveTranscriptionMonitorTask = nil
        liveTranscription = nil; liveTranscriptionMeetingID = nil; liveTranscriptionStartTask = nil
        liveTranscriptionStatusMessage = ""
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
