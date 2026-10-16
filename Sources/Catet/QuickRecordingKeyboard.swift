import AppKit
import Carbon
import SwiftUI

public final class QuickRecordingShortcut {
    public static let displayShortcut = "⌃⌥Space"

    private static let signature: OSType = fourCharCode("CATE")
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    public init(action: @escaping () -> Void) throws {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr,
                      receivedID.signature == QuickRecordingShortcut.signature,
                      receivedID.id == QuickRecordingShortcut.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<QuickRecordingShortcut>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { [weak shortcut] in shortcut?.action?() }
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            self.action = nil
            throw Self.registrationError(status: handlerStatus)
        }

        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard hotKeyStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            self.action = nil
            throw Self.registrationError(status: hotKeyStatus)
        }
    }

    deinit {
        action = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private static func registrationError(status: OSStatus) -> NSError {
        let description: String
        if status == eventHotKeyExistsErr {
            description = "The Control+Option+Space shortcut is already in use by another app."
        } else {
            description = "Could not register the Control+Option+Space shortcut (Carbon error \(status))."
        }
        return NSError(domain: "QuickRecordingShortcut", code: Int(status), userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

public struct QuickRecordingKeyboardHints: View {
    private let recording: Bool

    public init(recording: Bool) {
        self.recording = recording
    }

    public var body: some View {
        HStack(spacing: 8) {
            hint(key: "↵", label: recording ? "Stop" : "Record")
            hint(key: "esc", label: "Close")
            hint(key: "⌘↵", label: "Meetings")
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func hint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            KeyboardKeycap(key)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
