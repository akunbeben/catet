import AppKit
import AVFoundation
import CoreGraphics

private final class SettingsBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class PermissionsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var requestedSystemAudio = false
    private let microphoneStatus = NSTextField(wrappingLabelWithString: "")
    private let systemAudioStatus = NSTextField(wrappingLabelWithString: "")
    private let microphoneButton = NSButton(title: "Allow Access…", target: nil, action: nil)
    private let systemAudioButton = NSButton(title: "Allow Access…", target: nil, action: nil)
    private let captureSystemAudio = NSButton(checkboxWithTitle: "Include system audio", target: nil, action: nil)
    private let createMoM = NSButton(checkboxWithTitle: "Create meeting notes automatically", target: nil, action: nil)
    var onOpenCodexAccounts: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Catet Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        captureSystemAudio.target = self
        captureSystemAudio.action = #selector(saveRecordingPreferences)
        createMoM.target = self
        createMoM.action = #selector(saveRecordingPreferences)
        let recording = section("Recording", rows: [
            preference(captureSystemAudio, detail: "Record other apps alongside your microphone."),
            preference(createMoM, detail: "Sends the finished transcript to Codex.")
        ])

        microphoneButton.target = self
        microphoneButton.action = #selector(requestMicrophone)
        systemAudioButton.target = self
        systemAudioButton.action = #selector(requestSystemAudio)
        let permissions = section("Permissions", rows: [
            permission("Microphone", symbol: "mic", status: microphoneStatus, button: microphoneButton),
            permission("System audio", symbol: "speaker.wave.2", status: systemAudioStatus, button: systemAudioButton)
        ])
        let accounts = NSButton(title: "Codex Accounts…", target: self, action: #selector(openCodexAccounts))
        accounts.bezelStyle = .rounded
        let applications = NSButton(title: "Show App in Finder", target: self, action: #selector(showApplication))
        applications.bezelStyle = .inline
        applications.font = .systemFont(ofSize: 11)
        let footer = NSStackView(views: [label("Audio stays on this Mac.", size: 11), NSView(), applications])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        let stack = NSStackView(views: [title, recording, accounts, permissions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = SettingsBackgroundView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            recording.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.center()
        refresh()
    }

    private func label(_ text: String, size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        return field
    }

    private func preference(_ control: NSButton, detail: String) -> NSView {
        control.font = .systemFont(ofSize: 13)
        let description = label(detail)
        let row = NSStackView(views: [control, description])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        description.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func permission(_ title: String, symbol: String, status: NSTextField, button: NSButton) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 0
        let text = NSStackView(views: [heading, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        status.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityLabel("\(title) access")
        let row = NSStackView(views: [icon, text, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    private func section(_ title: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let card = NSBox()
        card.boxType = .custom
        card.borderColor = .separatorColor
        card.borderWidth = 0.5
        card.cornerRadius = 10
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = .zero
        let contents = NSStackView()
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 14
        contents.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                contents.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
            }
            contents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
        }
        let interior = card.contentView!
        interior.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: interior.leadingAnchor, constant: 16),
            contents.trailingAnchor.constraint(equalTo: interior.trailingAnchor, constant: -16),
            contents.topAnchor.constraint(equalTo: interior.topAnchor, constant: 16),
            contents.bottomAnchor.constraint(equalTo: interior.bottomAnchor, constant: -16)
        ])
        let section = NSStackView(views: [heading, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        card.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
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
        case .authorized: microphoneStatus.stringValue = "Allowed"
        case .denied: microphoneStatus.stringValue = "Access needed"
        case .restricted: microphoneStatus.stringValue = "Restricted by this Mac"
        case .notDetermined: microphoneStatus.stringValue = "Access needed"
        @unknown default: microphoneStatus.stringValue = "Status unavailable"
        }
        let systemAllowed = CGPreflightScreenCaptureAccess()
        microphoneStatus.textColor = microphone == .authorized ? .secondaryLabelColor : .systemOrange
        microphoneButton.title = microphone == .notDetermined ? "Allow Access…" : "System Settings…"
        microphoneButton.isEnabled = microphone != .restricted
        systemAudioStatus.stringValue = systemAllowed
            ? "Allowed"
            : requestedSystemAudio ? "Restart Catet after allowing access." : "Access needed. Only audio is saved."
        systemAudioStatus.textColor = systemAllowed ? .secondaryLabelColor : .systemOrange
        systemAudioButton.title = systemAllowed || requestedSystemAudio ? "System Settings…" : "Allow Access…"
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
        if requestedSystemAudio || CGPreflightScreenCaptureAccess() {
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
