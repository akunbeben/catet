import AppKit
import AVFoundation
import CoreGraphics

final class PermissionsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var requestedSystemAudio = false
    private let microphoneStatus = NSTextField(wrappingLabelWithString: "")
    private let systemAudioStatus = NSTextField(wrappingLabelWithString: "")
    private let microphoneButton = NSButton(title: "Request Microphone Access", target: nil, action: nil)
    private let systemAudioButton = NSButton(title: "Request System Audio Access", target: nil, action: nil)
    private let captureSystemAudio = NSButton(checkboxWithTitle: "Capture system audio", target: nil, action: nil)
    private let createMoM = NSButton(checkboxWithTitle: "Create meeting notes with Codex", target: nil, action: nil)
    var onOpenCodexAccounts: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Catet Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: CatetBrand.applicationIcon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let recordingHeading = NSTextField(labelWithString: "Recording")
        recordingHeading.font = .boldSystemFont(ofSize: 17)
        let disclosure = NSTextField(wrappingLabelWithString: "Creating meeting notes sends the transcript to Codex. Audio stays on your Mac.")
        captureSystemAudio.target = self
        captureSystemAudio.action = #selector(saveRecordingPreferences)
        createMoM.target = self
        createMoM.action = #selector(saveRecordingPreferences)
        let heading = NSTextField(labelWithString: "Privacy permissions")
        heading.font = .boldSystemFont(ofSize: 17)
        let intro = NSTextField(wrappingLabelWithString: "Allow access to record your microphone and meeting audio. Catet does not save screen images.")
        intro.maximumNumberOfLines = 0

        microphoneButton.target = self
        microphoneButton.action = #selector(requestMicrophone)
        systemAudioButton.target = self
        systemAudioButton.action = #selector(requestSystemAudio)
        let microphoneSettings = NSButton(title: "Open Microphone Settings", target: self, action: #selector(openMicrophoneSettings))
        let systemSettings = NSButton(title: "Open Screen & System Audio Recording Settings", target: self, action: #selector(openSystemAudioSettings))
        let applications = NSButton(title: "Show Catet in Applications", target: self, action: #selector(showApplication))
        let accounts = NSButton(title: "Codex accounts…", target: self, action: #selector(openCodexAccounts))

        let stack = NSStackView(views: [icon, recordingHeading, captureSystemAudio, createMoM, disclosure, accounts, heading, intro, microphoneStatus, microphoneButton, microphoneSettings, systemAudioStatus, systemAudioButton, systemSettings, applications])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            disclosure.widthAnchor.constraint(equalTo: stack.widthAnchor),
            microphoneStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            systemAudioStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)
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

    func applicationDidBecomeActive() { refresh() }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func refresh() {
        let preferences = RecordingPreferences.load() ?? RecordingPreferences()
        captureSystemAudio.state = preferences.captureSystemAudio ? .on : .off
        createMoM.state = preferences.createMoM ? .on : .off
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphone {
        case .authorized: microphoneStatus.stringValue = "Microphone: Allowed"
        case .denied: microphoneStatus.stringValue = "Microphone: Not allowed. Enable Catet in System Settings."
        case .restricted: microphoneStatus.stringValue = "Microphone: Restricted by this Mac."
        case .notDetermined: microphoneStatus.stringValue = "Microphone: Not yet requested."
        @unknown default: microphoneStatus.stringValue = "Microphone: Status unavailable."
        }
        let systemAllowed = CGPreflightScreenCaptureAccess()
        microphoneButton.title = microphone == .denied || microphone == .restricted ? "Open Microphone Settings" : "Request Microphone Access"
        microphoneButton.isEnabled = microphone != .authorized && microphone != .restricted
        systemAudioStatus.stringValue = systemAllowed
            ? "Screen & System Audio Recording: Allowed."
            : "Screen & System Audio Recording: Access needed. Restart Catet after changing access."
        systemAudioButton.isEnabled = !systemAllowed
    }

    @objc private func saveRecordingPreferences() {
        RecordingPreferences(captureSystemAudio: captureSystemAudio.state == .on, createMoM: createMoM.state == .on).save()
    }

    @objc private func openCodexAccounts() { onOpenCodexAccounts?() }
    @objc private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openMicrophoneSettings()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    @objc private func requestSystemAudio() {
        if requestedSystemAudio && !CGPreflightScreenCaptureAccess() {
            openSystemAudioSettings()
            return
        }
        _ = CGRequestScreenCaptureAccess()
        requestedSystemAudio = true
        refresh()
    }

    func requestSystemAudioOnLaunch() {
        _ = CGRequestScreenCaptureAccess()
        requestedSystemAudio = true
        refresh()
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }

    @objc private func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    @objc private func showApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
}
