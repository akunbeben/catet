import AppKit

struct RecordingPreferences: Equatable {
    var captureSystemAudio = true
    var createMoM = false

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let saved = defaults.dictionary(forKey: "recordingOptions"),
              let systemAudio = saved["captureSystemAudio"] as? Bool,
              let minutes = saved["createMoM"] as? Bool else { return nil }
        return Self(captureSystemAudio: systemAudio, createMoM: minutes)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(["captureSystemAudio": captureSystemAudio, "createMoM": createMoM], forKey: "recordingOptions")
    }
}

struct RecordingDialog {
    let alert = NSAlert()
    let systemAudio = NSButton(checkboxWithTitle: "Capture system audio", target: nil, action: nil)
    let minutes = NSButton(checkboxWithTitle: "Create meeting notes with Codex", target: nil, action: nil)

    init() {
        alert.messageText = "Start a new recording"
        alert.informativeText = "Creating meeting notes sends the transcript to Codex. Audio stays on your Mac. You can change these choices later in Settings."
        let preferences = RecordingPreferences()
        systemAudio.state = preferences.captureSystemAudio ? .on : .off
        minutes.state = preferences.createMoM ? .on : .off
        let options = NSStackView(views: [systemAudio, minutes])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10
        systemAudio.sizeToFit()
        minutes.sizeToFit()
        // NSAlert reserves its accessory's frame, not the stack's fitting size.
        let width = max(300, options.fittingSize.width)
        let height = systemAudio.frame.height + minutes.frame.height + options.spacing
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        options.frame = accessory.bounds
        options.autoresizingMask = [.width, .height]
        accessory.addSubview(options)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
    }
}

struct ShortRecordingDialog {
    let alert: NSAlert

    init?(duration: TimeInterval?) {
        guard let duration, duration.isFinite, duration > 0, duration <= 3 else { return nil }
        alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        let seconds = Int(ceil(duration))
        alert.messageText = "Keep this short recording?"
        alert.informativeText = "This recording is only \(seconds) \(seconds == 1 ? "second" : "seconds") long."
        alert.addButton(withTitle: "Keep")
        let discard = alert.addButton(withTitle: "Move to Trash")
        discard.hasDestructiveAction = true
    }
}

struct SystemAudioRecoveryDialog {
    let alert = NSAlert()

    init(issue: CaptureIssue) {
        alert.messageText = issue.permissionDenied ? "Allow system audio recording" : "System audio is unavailable"
        alert.informativeText = issue.recovery + "\n\nThe microphone is still recording."
        alert.addButton(withTitle: "Continue microphone only")
        alert.addButton(withTitle: "Stop and save")
        alert.addButton(withTitle: "Open Settings and stop")
    }
}
