import SwiftUI
import AppKit
import Combine

// Select the property wrapper explicitly. The SDK also exports a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct FloatingPill: View {
    enum Mode { case idle, recording, finishing }

    // Leaves room for the hover margin and the SwiftUI shadow around the surface.
    static let hoverPadding: CGFloat = 16
    static let surfaceHeight: CGFloat = 44
    static let keyboardHintHeight: CGFloat = 30
    static let animationDuration = 0.24
    static let cornerRadius: CGFloat = 14

    // Collapsed, the panel stays a quiet edge tab. While recording it keeps the timer visible.
    static func surfaceWidth(_ mode: Mode, expanded: Bool) -> CGFloat {
        switch (mode, expanded) {
        case (.idle, false): return 8
        case (.recording, false): return 84
        case (.finishing, false): return 40
        case (.idle, true): return 232
        case (.recording, true), (.finishing, true): return 268
        }
    }

    static func panelSize(_ mode: Mode, expanded: Bool, keyboard: Bool) -> NSSize {
        let height = surfaceHeight + (expanded && keyboard ? keyboardHintHeight : 0)
        return NSSize(width: surfaceWidth(mode, expanded: expanded) + hoverPadding, height: height + hoverPadding * 2)
    }

    @ObservedObject var controller: CatetController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    @ViewState private var collapseTask: Task<Void, Never>?

    private var mode: Mode { controller.pillMode }
    private var expanded: Bool { controller.pillExpanded }
    private var showsKeyboardHints: Bool { expanded && controller.quickRecordingKeyboardActive }
    // Idle, the full card slides out from the screen edge like a drawer; collapsed, only its edge shows.
    private var cardWidth: CGFloat { Self.surfaceWidth(mode, expanded: mode == .idle || expanded) }
    private var cardOffset: CGFloat { mode == .idle && !expanded ? Self.surfaceWidth(.idle, expanded: false) - cardWidth : 0 }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: Self.animationDuration) }
    private var finishingMessage: String {
        controller.liveTranscriptionStatusMessage.isEmpty ? "Finishing transcript" : controller.liveTranscriptionStatusMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content is laid out at full width and revealed by the surface's clip,
            // so status items keep their position while the surface grows or shrinks.
            row
                .frame(width: Self.surfaceWidth(mode, expanded: true), height: Self.surfaceHeight, alignment: .leading)
            if showsKeyboardHints {
                Divider().opacity(0.5)
                QuickRecordingKeyboardHints(recording: controller.isRecording)
                    .frame(width: Self.surfaceWidth(mode, expanded: true), height: Self.keyboardHintHeight - 1)
                    .transition(.opacity)
            }
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .offset(x: cardOffset)
        .padding(EdgeInsets(top: Self.hoverPadding, leading: 0, bottom: Self.hoverPadding, trailing: Self.hoverPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .preferredColorScheme(.dark)
        .animation(animation, value: expanded)
        .animation(animation, value: mode)
        .animation(animation, value: showsKeyboardHints)
        .onHover(perform: updateHover)
        .onChange(of: mode) { _, _ in controller.setPillExpanded(hovered) }
        .onChange(of: controller.quickRecordingKeyboardActive) { _, active in
            if !active || controller.isRecording { controller.setPillExpanded(hovered) }
        }
        .onDisappear { collapseTask?.cancel() }
    }

    @ViewBuilder private var row: some View {
        switch mode {
        case .idle: idleRow
        case .recording: recordingRow
        case .finishing: finishingRow
        }
    }

    private var idleRow: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                Button { controller.beginRecordingFlow() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text("Record").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.red, in: Capsule())
                }
                .buttonStyle(PillButtonStyle())
                .help(controller.quickRecordingShortcutAvailable ? "Start recording (\(QuickRecordingShortcut.displayShortcut))" : "Start recording")
                .accessibilityLabel("Start recording")
                Spacer(minLength: 0)
                if controller.quickRecordingShortcutAvailable && !showsKeyboardHints {
                    KeyboardKeycap(QuickRecordingShortcut.displayShortcut)
                }
                libraryButton
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
            Capsule().fill(.white.opacity(0.4))
                .frame(width: 2, height: 18)
                .padding(.trailing, 3)
                .opacity(expanded ? 0 : 1)
                .accessibilityHidden(expanded)
                .accessibilityLabel("Catet")
                .help("Catet")
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                RecordingDot(animated: !reduceMotion)
                timer.font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording in progress")
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                sourceIcon(controller.micAvailable ? "mic.fill" : "mic.slash.fill", active: controller.micAvailable,
                           label: controller.micAvailable ? "Microphone on" : "Microphone unavailable")
                sourceIcon(controller.systemAudioAvailable ? "speaker.wave.2.fill" : "speaker.slash.fill", active: controller.systemAudioAvailable,
                           label: controller.systemAudioAvailable ? "System audio on" : "System audio off")
                Button { controller.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white)
                        .frame(width: 10, height: 10)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(PillButtonStyle())
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
                libraryButton
            }
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
    }

    private var finishingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
                .frame(width: 16)
                .help(finishingMessage)
                .accessibilityLabel("Finishing transcription")
            HStack(spacing: 10) {
                Text(finishingMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                libraryButton
            }
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    private var libraryButton: some View {
        Button { controller.showLibrary() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PillButtonStyle(hoverFill: true))
        .help("Open meetings")
        .accessibilityLabel("Open meetings")
    }

    @ViewBuilder private var timer: some View {
        if let startedAt = controller.recordingStartedAt {
            RecordingElapsedTime(startedAt: startedAt)
        } else {
            Text("00:00")
        }
    }

    private func sourceIcon(_ symbol: String, active: Bool, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.secondary : Color.orange)
            .frame(width: 16)
            .help(label)
            .accessibilityLabel(label)
    }

    private func updateHover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            hovered = true
            controller.setPillExpanded(true)
        } else {
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                hovered = false
                controller.setPillExpanded(false)
            }
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    var hoverFill = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, hoverFill: hoverFill)
    }

    private struct PillButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Bool
        @ViewState private var hovered = false

        var body: some View {
            configuration.label
                .background(hoverFill && hovered ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .brightness(!hoverFill && hovered ? 0.06 : 0)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

// Pulses from the clock instead of a repeating animation, which would leak into layout changes of the panel.
private struct RecordingDot: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Circle().fill(.red)
                .frame(width: 8, height: 8)
                .opacity(animated ? 0.65 + 0.35 * cos(phase * 2 * .pi) : 1)
        }
        .frame(width: 8, height: 8)
    }
}

private struct RecordingElapsedTime: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(elapsed >= 3600 ? String(format: "%d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
                                 : String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
        }
    }
}

private struct LibraryKeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view, handle: handle)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.attach(to: view, handle: handle)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var handle: ((NSEvent) -> Bool)?
        weak var view: NSView?

        func attach(to view: NSView, handle: @escaping (NSEvent) -> Bool) {
            self.view = view
            self.handle = handle
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window, window.isKeyWindow, NSApp.modalWindow == nil else { return event }
                let first = window.firstResponder
                let editing = (first as? NSTextView).map { $0.isEditable || $0.isFieldEditor } == true
                    || first is NSTextField
                let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                if editing && !(command && ["f", "k"].contains(event.charactersIgnoringModifiers?.lowercased() ?? ""))
                    && event.keyCode != 53 { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

fileprivate final class LibraryScrollTarget: ObservableObject {
    weak var scrollView: NSScrollView?
}

// Plain reference so key handling can flag repeats without re-rendering the library.
fileprivate final class KeyRepeatState: ObservableObject {
    var active = false
}

private struct ScrollViewCapture: NSViewRepresentable {
    let target: LibraryScrollTarget

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(frame: .zero)
        view.target = target
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.target = target
        view.capture()
    }

    final class CaptureView: NSView {
        var target: LibraryScrollTarget?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            capture()
        }

        func capture() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            target?.scrollView = scrollView
        }
    }
}
struct LibraryView: View {
    @ObservedObject var controller: CatetController
    @ViewState private var selection: String?
    @ViewState private var markedMeetingIDs: Set<String> = []
    @ViewState private var tab = 0
    @ViewState private var searchText = ""
    @ViewState private var searchActive = false
    @ViewState private var detailFocused = false
    private var listHasFocus: Bool { !searchFocused && !detailFocused }
    @ViewState private var helpPresented = false
    @StateObject private var detailScrollTarget = LibraryScrollTarget()
    @StateObject private var keyRepeat = KeyRepeatState()
    @ViewState private var detailID: String?
    @ViewState private var detailTask: Task<Void, Never>?
    @ViewState private var pendingG = false
    @FocusState private var searchFocused: Bool

    private var selected: Meeting? { filteredMeetings.first { $0.id == selection } ?? filteredMeetings.first }
    private var detailMeeting: Meeting? { filteredMeetings.first { $0.id == (detailID ?? selection) } ?? selected }
    private var filteredMeetings: [Meeting] {
        guard !searchText.isEmpty else { return controller.meetings }
        return controller.meetings.filter { $0.title.localizedStandardContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(nsImage: CatetBrand.mark).resizable().scaledToFit().frame(width: 18, height: 18)
                    Text("Meetings").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { controller.importAudio() } label: {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Import audio").accessibilityLabel("Import audio")
                }
                Button {
                    controller.isRecording ? controller.stopRecording() : controller.beginRecordingFlow()
                } label: {
                    Label(controller.isRecording ? "Stop recording" : "New recording", systemImage: controller.isRecording ? "stop.circle.fill" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(controller.isRecording ? .red : .accentColor)
                .accessibilityIdentifier("new-recording")

                if searchActive {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search meetings", text: $searchText)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .onSubmit {
                                searchFocused = false
                                detailFocused = false
                            }
                            .accessibilityLabel("Search meetings")
                        Button {
                            searchText = ""
                            searchFocused = true
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search")
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filteredMeetings) { meeting in
                                MeetingRow(meeting: meeting,
                                           selected: selection == meeting.id,
                                           focused: selection == meeting.id && listHasFocus,
                                           showsCheckbox: !markedMeetingIDs.isEmpty,
                                           marked: markedMeetingIDs.contains(meeting.id),
                                           mark: { marked in
                                               selection = meeting.id
                                               focusList()
                                               if marked { markedMeetingIDs.insert(meeting.id) }
                                               else { markedMeetingIDs.remove(meeting.id) }
                                           },
                                           open: { select(meeting, proxy: proxy) })
                                    .equatable()
                                    .id(meeting.id)
                            }
                            if filteredMeetings.isEmpty {
                                Text(searchText.isEmpty ? "No meetings yet" : "No matching meetings")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: selection) { _, id in
                        // Animating every step makes held j/k keys queue up overlapping scroll animations.
                        if let id, filteredMeetings.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: nil) }
                    }
                    .onChange(of: searchText) { _, _ in
                        markedMeetingIDs.removeAll()
                        if let id = selection, !filteredMeetings.contains(where: { $0.id == id }) {
                            selection = filteredMeetings.first?.id
                        } else if selection == nil {
                            selection = filteredMeetings.first?.id
                        }
                    }
                }

                HStack(spacing: 8) {
                    if !markedMeetingIDs.isEmpty {
                        Text("\(markedMeetingIDs.count) selected")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button(role: .destructive, action: deleteMarkedMeetings) {
                            HStack(spacing: 5) {
                                Label("Delete", systemImage: "trash")
                                KeyboardKeycap("D")
                            }
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                        .help("Move selected meetings to Trash (D)")
                        .accessibilityLabel("Delete selected meetings")
                        .accessibilityIdentifier("delete-selected-meetings")
                    } else {
                        HStack(spacing: 5) {
                            if searchActive {
                                KeyboardKeycap("Esc")
                                Text("Clear search")
                            } else if detailFocused {
                                KeyboardKeycap("H")
                                Text("Meetings")
                            } else if !filteredMeetings.isEmpty {
                                KeyboardKeycap("Space")
                                Text("Select")
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    Button { helpPresented.toggle() } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 15))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Keyboard shortcuts")
                    .accessibilityLabel("Keyboard shortcuts")
                    .popover(isPresented: $helpPresented, arrowEdge: .bottom) {
                        KeyboardShortcutsPopover(isPresented: $helpPresented,
                                                 globalRecordingAvailable: controller.quickRecordingShortcutAvailable)
                    }
                }
                .frame(height: 24)
            }
            .padding(16).padding(.top, 28).frame(width: 264)
            .background(SidebarMaterial())
            Divider()
            if let meeting = detailMeeting {
                MeetingDetail(meeting: meeting, controller: controller, tab: $tab, contentFocused: $detailFocused, scrollTarget: detailScrollTarget)
            } else {
                ContentUnavailableView(searchText.isEmpty ? "No meetings yet" : "No matching meetings",
                                       systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                                       description: Text(searchText.isEmpty ? "Record a meeting or import an audio file." : "Try another search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 650, minHeight: 460)
        .background(LibraryKeyMonitor(handle: handleKey).frame(width: 0, height: 0))
        .onAppear {
            if selection == nil { selection = controller.meetings.first?.id }
        }
        .onChange(of: selection) { _, id in
            detailTask?.cancel()
            // While a navigation key is held, rebuild the detail only after the keys settle.
            guard keyRepeat.active else { detailID = id; return }
            keyRepeat.active = false
            detailTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                detailID = id
            }
        }
        .onDisappear { detailTask?.cancel() }
        .onChange(of: controller.meetings) { _, _ in
            let ids = filteredMeetings.map(\.id)
            markedMeetingIDs.formIntersection(ids)
            if !ids.contains(selection ?? "") {
                selection = ids.first
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        keyRepeat.active = event.isARepeat
        if helpPresented && event.keyCode == 53 {
            helpPresented = false
            return true
        }
        if command && !flags.contains(.control) {
            if key == "f" || key == "k" { beginSearch(); return true }
            if key == "1" { tab = 0; detailFocused = true; return true }
            if key == "2" { tab = 1; detailFocused = true; return true }
            return false
        }
        if searchFocused {
            if event.keyCode == 53 {
                searchText = ""
                searchActive = false
                searchFocused = false
                focusList()
                return true
            }
            return false
        }
        if flags.contains(.control) { return false }
        if shift && (key == "?" || key == "/") { helpPresented.toggle(); return true }
        if key == "/" && !option && !shift { beginSearch(); return true }
        if event.keyCode == 53 {
            if searchActive { searchText = "" }
            focusList()
            return true
        }
        if option && (event.keyCode == 126 || event.keyCode == 125) {
            moveSelection(delta: event.keyCode == 126 ? -1 : 1)
            return true
        }
        if listHasFocus && !option && !shift {
            if event.keyCode == 49 {
                pendingG = false
                if !event.isARepeat, let meeting = selected {
                    if !markedMeetingIDs.insert(meeting.id).inserted { markedMeetingIDs.remove(meeting.id) }
                }
                return true
            }
            if key == "d" {
                pendingG = false
                if !event.isARepeat { deleteMarkedMeetings() }
                return true
            }
        }
        if detailFocused {
            switch event.keyCode {
            case 49: scrollDetail(by: shift ? -440 : 440); return true
            case 116: scrollDetail(by: -440); return true
            case 121: scrollDetail(by: 440); return true
            case 126: scrollDetail(by: -48); return true
            case 125: scrollDetail(by: 48); return true
            default: break
            }
            if key == "j" || key == "k" {
                scrollDetail(by: key == "j" ? 48 : -48)
                return true
            }
        }
        if pendingG {
            pendingG = false
            if key == "g" { selectIndex(0); return true }
        }
        if key == "g" && !shift { pendingG = true; return true }
        if key == "g" && shift { selectIndex(filteredMeetings.count - 1); return true }
        if event.keyCode == 126 || key == "k" { moveSelection(delta: -1); return true }
        if event.keyCode == 125 || key == "j" { moveSelection(delta: 1); return true }
        if key == "h" { focusList(); return true }
        if event.keyCode == 36 || key == "l" {
            searchFocused = false
            searchActive = false
            detailFocused = true
            return true
        }
        return false
    }

    private func deleteMarkedMeetings() {
        let meetings = filteredMeetings.filter { markedMeetingIDs.contains($0.id) }
        guard !meetings.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = meetings.count == 1 ? "Move this meeting to Trash?" : "Move \(meetings.count) meetings to Trash?"
        alert.informativeText = meetings.count == 1
            ? "“\(meetings[0].title)” and its recording, transcript, and notes can be restored from Trash."
            : "Their recordings, transcripts, and notes can be restored from Trash."
        let hints = NSHostingView(rootView: DeletionKeyboardHints())
        hints.setFrameSize(hints.fittingSize)
        alert.accessoryView = hints
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        // NSAlert removes Return-based key equivalents from destructive buttons.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === alert.window, event.window === alert.window,
                  !event.isARepeat, event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return event }
            trash.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var failure: Error?
        do { try controller.store.moveToTrash(ids: Set(meetings.map(\.id))) }
        catch { failure = error }
        controller.refresh()
        markedMeetingIDs.formIntersection(controller.meetings.map(\.id))
        if let failure { controller.reportError(failure) }
    }

    private func scrollDetail(by delta: CGFloat) {
        guard let scrollView = detailScrollTarget.scrollView else { return }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? clipView.bounds.height
        let maxY = max(0, documentHeight - clipView.bounds.height)
        let origin = NSPoint(x: clipView.bounds.origin.x,
                             y: min(max(clipView.bounds.origin.y + delta, 0), maxY))
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func beginSearch() {
        searchActive = true
        searchFocused = true
        detailFocused = false
    }

    private func focusList() {
        searchFocused = false
        searchActive = false
        detailFocused = false
    }

    private func select(_ meeting: Meeting, proxy: ScrollViewProxy) {
        selection = meeting.id
        searchFocused = false
        detailFocused = false
        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(meeting.id, anchor: nil) }
    }

    private func moveSelection(delta: Int) {
        guard !filteredMeetings.isEmpty else { return }
        let current = filteredMeetings.firstIndex(where: { $0.id == selection }) ?? 0
        selectIndex(min(max(current + delta, 0), filteredMeetings.count - 1))
    }

    private func selectIndex(_ index: Int) {
        guard filteredMeetings.indices.contains(index) else { return }
        let id = filteredMeetings[index].id
        selection = id
        detailFocused = false
    }
}

// Equatable so a selection change re-renders only the rows whose state changed.
private struct MeetingRow: View, Equatable {
    let meeting: Meeting
    let selected: Bool
    let focused: Bool
    let showsCheckbox: Bool
    let marked: Bool
    let mark: (Bool) -> Void
    let open: () -> Void
    @ViewState private var hovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.meeting == rhs.meeting && lhs.selected == rhs.selected && lhs.focused == rhs.focused
            && lhs.showsCheckbox == rhs.showsCheckbox && lhs.marked == rhs.marked
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Select \(meeting.title)", isOn: Binding(get: { marked }, set: mark))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .opacity(showsCheckbox || hovered || marked ? 1 : 0)
                .accessibilityIdentifier("select-meeting-\(meeting.id)")
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(meeting.title)
                    HStack(spacing: 6) {
                        Text(rowDate).lineLimit(1)
                        Spacer(minLength: 6)
                        // Complete is the normal end state, so only other states get a badge.
                        if meeting.status != "complete" {
                            HStack(spacing: 4) {
                                if meeting.status == "recording" { Circle().fill(.red).frame(width: 5, height: 5) }
                                Text(meeting.statusLabel)
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(statusColor.opacity(0.12), in: Capsule())
                            .fixedSize()
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("meeting-\(meeting.id)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.17) : hovered ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
            }
        }
        .onHover { hovered = $0 }
    }

    private var statusColor: Color {
        switch meeting.status {
        case "failed", "recording": return .red
        case "waiting_for_limit": return .orange
        case "transcribed": return .blue
        default: return .secondary
        }
    }

    private var rowDate: String {
        guard let date = meeting.createdDate else { return meeting.created_at }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated).hour().minute()
                                       : .dateTime.day().month(.abbreviated).year().hour().minute())
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var controller: CatetController
    @Binding var tab: Int
    @Binding var contentFocused: Bool
    fileprivate let scrollTarget: LibraryScrollTarget
    @ViewState private var loadedOutputs: LoadedOutputs?
    // The detail view is reused across meetings, so ignore outputs that belong to the previous meeting.
    private var outputs: LoadedOutputs? { loadedOutputs?.directory == meeting.directory ? loadedOutputs : nil }
    private var transcript: String { outputs?.transcript ?? "" }
    private var mom: String { outputs?.mom ?? "" }
    private var transcriptSegments: [TranscriptSegment] { outputs?.segments ?? [] }
    private var minutesBlocks: [MinutesBlock] { outputs?.minutes ?? [] }
    private var hasTranscript: Bool {
        FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("transcript.json").path)
            || FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("transcript.txt").path)
    }
    private var hasMoM: Bool { FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("mom.md").path) }
    private var momActionTitle: String { hasMoM ? "Regenerate notes" : "Create notes" }
    private var canCreateMoM: Bool {
        hasTranscript && meeting.status != "recording" && meeting.status != "transcribing" && meeting.status != "summarizing"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meeting.title).font(.system(size: 22, weight: .semibold)).lineLimit(2).help(meeting.title)
                    Text(meeting.status == "complete" ? createdText : "\(createdText) · \(meeting.statusLabel)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if meeting.status == "recorded" {
                        Button("Process saved recording") { controller.process(meeting, mom: meeting.generate_mom == true) }
                    }
                    Button(hasTranscript ? "Transcribe again" : "Retry transcription") { controller.retryTranscription(meeting) }
                        .disabled(meeting.status == "recording" || meeting.status == "transcribing" || meeting.status == "summarizing")
                    if canCreateMoM {
                        Button(momActionTitle) { controller.createMoM(meeting) }
                    }
                    Menu("Codex account") {
                        ForEach(controller.codexAccounts) { account in
                            Button(account.label + (account.id == controller.selectedCodexAccountID ? " ✓" : "")) {
                                controller.selectCodexAccount(account.id)
                            }
                            .disabled(account.id != "default" && !account.isAuthenticated)
                        }
                        Divider()
                        Button("Manage accounts…") { controller.openCodexAccounts() }
                    }
                    Button("Open folder") { controller.openFolder(meeting) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Meeting actions")
                .accessibilityLabel("Meeting actions")
            }
            if (meeting.status == "recording" || meeting.status == "transcribing")
                && !controller.liveTranscriptionStatusMessage.isEmpty {
                Label(controller.liveTranscriptionStatusMessage, systemImage: "waveform")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let message = meeting.failureMessage { failureBanner(message) }
            if let warning = meeting.capture_warning {
                VStack(alignment: .leading, spacing: 6) {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("System audio settings") { controller.openAudioSettings() }
                }.font(.callout)
            }
            HStack(spacing: 10) {
                Picker("Output", selection: $tab) {
                    Text("Transcript").tag(0)
                    Text("Notes").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 12)
                if meeting.status == "recorded" {
                    Button("Process recording") { controller.process(meeting, mom: meeting.generate_mom == true) }
                        .buttonStyle(.borderedProminent).fixedSize()
                } else if meeting.status == "failed" && (!hasTranscript || meeting.error_kind == "transcription") {
                    Button("Retry transcription") { controller.retryTranscription(meeting) }
                        .buttonStyle(.borderedProminent).fixedSize()
                } else if hasTranscript && (!hasMoM || meeting.error != nil) {
                    Button(meeting.error != nil ? "Retry notes" : "Create notes") { controller.createMoM(meeting) }
                        .buttonStyle(.borderedProminent).fixedSize()
                        .disabled(!canCreateMoM)
                        .disabled(controller.codexAccounts.first { $0.id == controller.selectedCodexAccountID }?.retryAt.map { $0 > Date() } == true)
                }
            }
            Group {
                if tab == 0 { transcriptOutput }
                else { momOutput.id(meeting.id) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(24).padding(.top, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting-detail-\(meeting.id)")
            .simultaneousGesture(TapGesture().onEnded { contentFocused = true })
            .task(id: OutputRequest(directory: meeting.directory, status: meeting.status)) {
                await loadOutputsWhileActive()
            }
    }

    private func failureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(meeting.isUsageLimited ? "\(controller.codexAccounts.first { $0.id == (meeting.codex_account_id ?? "default") }?.label ?? "This Codex account") has reached its usage limit." : message,
                  systemImage: meeting.isUsageLimited ? "clock" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(meeting.isUsageLimited ? Color.orange : Color.red)
            if meeting.status == "waiting_for_limit", let retry = meeting.retryDate {
                Text("Notes will be retried \(retry.formatted(date: .abbreviated, time: .shortened)) while Catet is open.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("If Catet is closed or your Mac is asleep, the retry will run when Catet is active again.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if meeting.isUsageLimited {
                Text("Choose another account, or try again after your limit resets.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if meeting.isUsageLimited || meeting.error_kind == "authentication" {
                    Menu("Use another account") {
                        ForEach(controller.codexAccounts.filter { $0.id != (meeting.codex_account_id ?? "default") && ($0.id == "default" || $0.isAuthenticated) }) { account in
                            Button(account.label) { controller.createMoM(meeting, accountID: account.id) }
                                .disabled(account.retryAt.map { $0 > Date() } == true)
                        }
                        Divider()
                        Button("Manage accounts…") { controller.openCodexAccounts() }
                    }.fixedSize()
                }
                Button("Show diagnostics") { controller.openDiagnostics(meeting) }
                    .buttonStyle(.link)
            }.font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((meeting.isUsageLimited ? Color.orange : Color.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("meeting-recovery")
    }
    private var transcriptOutput: some View {
        VStack(alignment: .leading, spacing: 0) {
            if outputs?.isLivePreview == true {
                HStack(spacing: 8) {
                    Label("Live transcript · preview", systemImage: "waveform")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !controller.liveTranscriptionStatusMessage.isEmpty {
                        Text(controller.liveTranscriptionStatusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .top], 20)
            }
            // Keep the text view alive while switching meetings; rebuilding it is the expensive part.
            TranscriptTextView(content: TranscriptContent(id: meeting.directory, segments: transcriptSegments, plainText: transcript),
                               scrollTarget: scrollTarget) { contentFocused = true }
                .overlay(alignment: .topLeading) {
                    if outputs != nil && transcriptSegments.isEmpty && transcript.isEmpty {
                        Text("No transcript yet.").font(.system(size: 14)).foregroundStyle(.secondary).padding(20)
                    }
                }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
    private var momOutput: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if outputs == nil {
                    EmptyView()
                } else if mom.isEmpty {
                    Text("No meeting notes yet.").foregroundStyle(.secondary)
                } else if minutesBlocks.isEmpty {
                    Text(mom).font(.system(size: 14)).lineSpacing(5)
                } else {
                    ForEach(minutesBlocks) { block in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let marker = block.marker {
                                Text(marker).foregroundStyle(.secondary).frame(minWidth: 12, alignment: .leading)
                            }
                            Text(block.text)
                                .font(.system(size: block.heading == 1 ? 20 : block.heading != nil ? 16 : 14,
                                              weight: block.heading != nil ? .semibold : .regular))
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, block.heading != nil && block.id != 0 ? 6 : 0)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
            .padding(24)
            .background(ScrollViewCapture(target: scrollTarget).frame(width: 0, height: 0))
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
    private struct TranscriptDocument: Decodable { let segments: [TranscriptSegment] }
    private struct MinutesBlock: Identifiable, Sendable {
        let id: Int
        let text: AttributedString
        let heading: Int?
        let marker: String?
    }
    private struct OutputRequest: Equatable {
        let directory: URL
        let status: String
    }
    private struct LoadedOutputs: Sendable {
        let transcript: String
        let mom: String
        let segments: [TranscriptSegment]
        let minutes: [MinutesBlock]
        let isLivePreview: Bool
        let directory: URL
    }
    private var createdText: String {
        guard let date = meeting.createdDate else { return meeting.created_at }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    @MainActor private func loadOutputsWhileActive() async {
        repeat {
            await loadOutputs()
            guard meeting.status == "recording" || meeting.status == "transcribing", !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
        } while !Task.isCancelled
    }
    @MainActor private func loadOutputs() async {
        let directory = meeting.directory
        let work = Task.detached(priority: .userInitiated) { try Self.readOutputs(in: directory) }
        let loaded = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let loaded else { return }
        loadedOutputs = loaded
    }

    nonisolated private static func readOutputs(in directory: URL) throws -> LoadedOutputs {
        try Task.checkCancellation()
        let finalTranscriptExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.txt").path)
        let transcriptName = finalTranscriptExists ? "transcript.json" : "live-transcript.json"
        let textName = finalTranscriptExists ? "transcript.txt" : "live-transcript.txt"
        let segments = (try? JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: directory.appendingPathComponent(transcriptName))))?.segments.filter {
            $0.start.isFinite && $0.start >= 0 && $0.start < Double(Int.max) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        try Task.checkCancellation()
        let transcript = segments.isEmpty ? (try? String(contentsOf: directory.appendingPathComponent(textName), encoding: .utf8)) ?? "" : ""
        let mom = (try? String(contentsOf: directory.appendingPathComponent("mom.md"), encoding: .utf8)) ?? ""
        try Task.checkCancellation()
        var minutes: [MinutesBlock] = []
        if let parsed = try? AttributedString(markdown: mom) {
            for (intent, range) in parsed.runs[\.presentationIntent] {
                try Task.checkCancellation()
                var heading: Int?
                var ordinal: Int?
                var ordered = false
                for component in intent?.components ?? [] {
                    switch component.kind {
                    case .header(let level): heading = level
                    case .listItem(let value): ordinal = value
                    case .orderedList: ordered = true
                    default: break
                    }
                }
                minutes.append(MinutesBlock(id: minutes.count, text: AttributedString(parsed[range]),
                                           heading: heading, marker: ordinal.map { ordered ? "\($0)." : "•" }))
            }
        }
        try Task.checkCancellation()
        return LoadedOutputs(transcript: transcript, mom: mom, segments: segments, minutes: minutes,
                             isLivePreview: !finalTranscriptExists, directory: directory)
    }
}

fileprivate struct TranscriptSegment: Decodable, Equatable, Sendable { let start: TimeInterval; let text: String }

// Long transcripts render as one AppKit text view. A SwiftUI Text per segment made each meeting switch take ~90 ms.
private struct TranscriptTextView: NSViewRepresentable {
    let content: TranscriptContent
    let scrollTarget: LibraryScrollTarget
    let focus: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TranscriptNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollTarget.scrollView = scrollView
        guard let textView = scrollView.documentView as? TranscriptNSTextView else { return }
        textView.focus = focus
        guard textView.content != content else { return }
        let otherMeeting = textView.content?.id != content.id
        textView.content = content
        textView.textStorage?.setAttributedString(Self.render(content))
        if otherMeeting { textView.scroll(.zero) }
    }

    private static func render(_ content: TranscriptContent) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: 14)
        guard !content.segments.isEmpty else {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            return NSAttributedString(string: content.plainText, attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        }
        let indent: CGFloat = 66
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 7
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.headIndent = indent
        let time: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let text: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let result = NSMutableAttributedString()
        for (index, segment) in content.segments.enumerated() {
            result.append(NSAttributedString(string: shortTimestamp(segment.start) + "\t", attributes: time))
            result.append(NSAttributedString(string: segment.text + (index == content.segments.count - 1 ? "" : "\n"), attributes: text))
        }
        return result
    }

    private static func shortTimestamp(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct TranscriptContent: Equatable {
    let id: URL
    let segments: [TranscriptSegment]
    let plainText: String
}

private final class TranscriptNSTextView: NSTextView {
    var content: TranscriptContent?
    var focus: (() -> Void)?

    // Keep the transcript column readable on wide windows.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = NSSize(width: max(20, (newSize.width - 760) / 2), height: 20)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func mouseDown(with event: NSEvent) {
        focus?()
        super.mouseDown(with: event)
    }
}

extension CatetController {
    func beginRecordingFlow() {
        guard !hasActiveRecordingLifecycle && !isStoppingRecording else { showLibrary(); return }
        let preferences: RecordingPreferences
        if let saved = RecordingPreferences.load() {
            preferences = saved
        } else {
            let dialog = RecordingDialog()
            guard dialog.alert.runModal() == .alertFirstButtonReturn else { return }
            preferences = RecordingPreferences(captureSystemAudio: dialog.systemAudio.state == .on, createMoM: dialog.minutes.state == .on)
            preferences.save()
        }
        startRecording(generateMoM: preferences.createMoM, includeSystemAudio: preferences.captureSystemAudio)
    }
    func startRecording(generateMoM: Bool = false, includeSystemAudio: Bool = true) {
        guard !hasActiveRecordingLifecycle && !isStoppingRecording else { return }
        didOfferMicOnly = false
        recordingFailure = nil; recordingReady = false; pendingRecordingStop = false
        processAfterRecordingStops = true
        liveTranscriptionStatusMessage = ""
        do {
            let meeting = try store.newMeeting(title: "Meeting \(DateFormatter.catet.string(from: Date()))", generateMoM: generateMoM)
            do { try store.reserveForLiveTranscription(meeting.id) }
            catch {
                let reservationError = error
                do { try store.update(id: meeting.id) { $0.status = "failed"; $0.error = reservationError.localizedDescription } }
                catch {
                    refresh()
                    throw StoreError.processing("Could not reserve this meeting for recording: \(reservationError.localizedDescription) Could not save failure state: \(error.localizedDescription)")
                }
                refresh()
                throw reservationError
            }
            meetings.insert(meeting, at: 0); currentRecordingID = meeting.id; recordingStartedAt = nil
            recorder.start(directory: meeting.directory, includeSystemAudio: includeSystemAudio, meetingLockHeld: true) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.currentRecordingID == meeting.id else { return }
                    self.recordingReady = true
                    if case .failure(let error) = result {
                        self.recordingFailure = error.localizedDescription
                    }
                    if self.pendingRecordingStop || self.recordingFailure != nil { self.stopRecording() }
                }
            }
            recordingReady = true
        } catch { reportError(error) }
    }
}
