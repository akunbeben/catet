import SwiftUI

struct KeyboardKeycap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.18), lineWidth: 0.5))
            .fixedSize()
    }
}

struct KeyboardShortcutsPopover: View {
    @Binding var isPresented: Bool
    let globalRecordingAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close keyboard shortcuts")
            }
            Divider()
            section("Meetings") {
                shortcut("Search", "⌘F", "⌘K", "/")
                shortcut("Move between meetings", "J", "K", "↑", "↓")
                shortcut("First meeting", "G G")
                shortcut("Last meeting", "⇧G")
                shortcut("Open meeting", "↵", "L")
                shortcut("Back to list", "H", "Esc")
                shortcut("Switch meetings", "⌥↑", "⌥↓")
            }
            section("Selection") {
                shortcut("Select / deselect", "Space")
                shortcut("Delete selected", "D")
            }
            section("Reading") {
                shortcut("Transcript", "⌘1")
                shortcut("Notes", "⌘2")
                shortcut("Scroll", "J", "K", "↑", "↓")
                shortcut("Page down", "Space", "PgDn")
                shortcut("Page up", "⇧Space", "PgUp")
            }
            section("Recording") {
                shortcut("Quick recording", "⇧⌘R")
                if globalRecordingAvailable {
                    shortcut("Global shortcut", QuickRecordingShortcut.displayShortcut)
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-shortcuts-popover")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4, content: content)
        }
    }

    private func shortcut(_ title: String, _ first: String, _ second: String? = nil,
                          _ third: String? = nil, _ fourth: String? = nil) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 12)).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                KeyboardKeycap(first)
                if let second {
                    separator
                    KeyboardKeycap(second)
                }
                if let third {
                    separator
                    KeyboardKeycap(third)
                }
                if let fourth {
                    separator
                    KeyboardKeycap(fourth)
                }
            }
            .fixedSize()
        }
        .frame(minHeight: 18)
    }

    private var separator: some View {
        Text("/").font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}

struct DeletionKeyboardHints: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                KeyboardKeycap("⌘↵")
                Text("Confirm")
            }
            HStack(spacing: 5) {
                KeyboardKeycap("Esc")
                Text("Cancel")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
