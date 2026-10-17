import SwiftUI
import AppKit
import Combine

// Select the property wrapper explicitly. The SDK also exports a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

struct FloatingPill: View {
    static let hoverPadding: CGFloat = 12
    static let surfaceHeight: CGFloat = 48
    static let collapsedWidth: CGFloat = 12 + hoverPadding
    static let expandedWidth: CGFloat = 280 + hoverPadding
    static let height: CGFloat = surfaceHeight + hoverPadding * 2
    static let keyboardHintHeight: CGFloat = 32
    static let animationDuration = 0.24

    @ObservedObject var controller: CatetController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovered = false
    @ViewState private var collapseTask: Task<Void, Never>?
    private var transitionAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: Self.animationDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                if controller.pillExpanded {
                    controls
                        .frame(width: Self.expandedWidth - Self.hoverPadding, height: Self.surfaceHeight)
                        .transition(.opacity)
                } else {
                    Capsule().fill(controller.isRecording ? Color.red : Color.white.opacity(0.45))
                        .frame(width: controller.isRecording ? 4 : 3, height: 22)
                        .frame(width: Self.collapsedWidth - Self.hoverPadding, height: Self.surfaceHeight)
                        .accessibilityLabel(controller.isRecording ? "Recording in progress" : "Catet")
                        .help(controller.isRecording ? "Recording in progress" : "Catet")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.surfaceHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if controller.pillExpanded && controller.quickRecordingKeyboardActive {
                QuickRecordingKeyboardHints(recording: controller.isRecording)
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(EdgeInsets(top: Self.hoverPadding, leading: 0, bottom: Self.hoverPadding, trailing: Self.hoverPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .preferredColorScheme(.dark)
        .animation(transitionAnimation, value: controller.pillExpanded)
        .animation(transitionAnimation, value: controller.isRecording)
        .animation(transitionAnimation, value: controller.quickRecordingKeyboardActive)
        .onHover(perform: updateHover)
        .onChange(of: controller.isRecording) { _, _ in controller.setPillExpanded(hovered) }
        .onChange(of: controller.quickRecordingKeyboardActive) { _, active in
            if !active || controller.isRecording { controller.setPillExpanded(hovered) }
        }
        .onDisappear { collapseTask?.cancel() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if controller.isRecording {
                Circle().fill(.red).frame(width: 6, height: 6)
            } else {
                Image(nsImage: CatetBrand.mark).resizable().scaledToFit().frame(width: 14, height: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.isRecording ? "Recording" : "Catet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Group {
                    if controller.isRecording {
                        if let startedAt = controller.recordingStartedAt {
                            RecordingElapsedTime(startedAt: startedAt)
                        } else {
                            Text("00:00")
                        }
                    } else {
                        Text("Ready to record")
                    }
                }
                    .font(.system(size: 12, weight: .semibold, design: controller.isRecording ? .monospaced : .default))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .fixedSize()
            Spacer(minLength: 0)
            if controller.isRecording {
                HStack(spacing: 8) {
                    sourceIcon(controller.micAvailable ? "mic.fill" : "mic.slash.fill",
                               active: controller.micAvailable, label: controller.micAvailable ? "Microphone on" : "Microphone unavailable")
                    sourceIcon(controller.systemAudioAvailable ? "speaker.wave.2.fill" : "speaker.slash.fill",
                               active: controller.systemAudioAvailable, label: controller.systemAudioAvailable ? "System audio on" : "System audio off")
                }
                Button { controller.stopRecording() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.red, in: Circle())
                }
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
            } else {
                Button { controller.beginRecordingFlow() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(.white).frame(width: 6, height: 6)
                        Text("Record").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.red, in: Capsule())
                }
                .accessibilityLabel("Start recording")
            }
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18)
            Button { controller.showLibrary() } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .help("Open meetings")
            .accessibilityLabel("Open meetings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private func sourceIcon(_ symbol: String, active: Bool, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.white.opacity(0.65) : Color.orange)
            .frame(width: 14)
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

private struct RecordingElapsedTime: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
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
    @ViewState private var pendingG = false
    @FocusState private var searchFocused: Bool

    private var selected: Meeting? { filteredMeetings.first { $0.id == selection } ?? filteredMeetings.first }
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
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("Select \(meeting.title)", isOn: Binding(
                                        get: { markedMeetingIDs.contains(meeting.id) },
                                        set: { marked in
                                            selection = meeting.id
                                            focusList()
                                            if marked { markedMeetingIDs.insert(meeting.id) }
                                            else { markedMeetingIDs.remove(meeting.id) }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityIdentifier("select-meeting-\(meeting.id)")
                                    Button {
                                        select(meeting, proxy: proxy)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(meeting.title)
                                            HStack {
                                                Text(meetingDate(meeting.created_at)).lineLimit(1)
                                                Spacer(minLength: 6)
                                                Text(meeting.statusLabel)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(statusColor(meeting.status))
                                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                                    .background(statusColor(meeting.status).opacity(0.10), in: Capsule())
                                                    .fixedSize()
                                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selection == meeting.id ? .isSelected : [])
                                    .accessibilityIdentifier("meeting-\(meeting.id)")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(selection == meeting.id ? Color.accentColor.opacity(0.17) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    if selection == meeting.id && listHasFocus {
                                        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.72), lineWidth: 1)
                                    }
                                }
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
                        if let id, filteredMeetings.contains(where: { $0.id == id }) {
                            withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: nil) }
                        }
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

                if !markedMeetingIDs.isEmpty {
                    HStack {
                        Text("\(markedMeetingIDs.count) selected").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive, action: deleteMarkedMeetings) {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("delete-selected-meetings")
                    }
                }

                if listHasFocus {
                    HStack(spacing: 6) {
                        KeyboardKeycap("Space")
                        Text("select").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        KeyboardKeycap("D")
                        Text("delete").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    if searchActive {
                        KeyboardKeycap("Esc")
                        Text("clear search").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if detailFocused {
                        KeyboardKeycap("h")
                        Text("meetings").font(.system(size: 10)).foregroundStyle(.secondary)
                        KeyboardKeycap("j/k")
                        Text("scroll").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        KeyboardKeycap("j/k")
                        Text("navigate").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { helpPresented.toggle() } label: {
                        Image(systemName: "questionmark.circle").font(.system(size: 15))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Keyboard shortcuts")
                    .accessibilityLabel("Keyboard shortcuts")
                    .popover(isPresented: $helpPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Keyboard shortcuts").font(.system(size: 13, weight: .semibold))
                            shortcut("Keyboard help", "?")
                            shortcut("Search", "⌘F / ⌘K / /")
                            shortcut("Move between meetings", "J / K · ↑ / ↓")
                            shortcut("First / last meeting", "G G / ⇧G")
                            shortcut("Select / deselect meeting", "Space")
                            shortcut("Delete selected meetings", "D")
                            shortcut("Open / return to list", "Return / L · H / Esc")
                            shortcut("Switch meetings", "⌥↑ / ⌥↓")
                            shortcut("Transcript / Notes", "⌘1 / ⌘2")
                            shortcut("Scroll content", "J / K · Space · PgUp/PgDn")
                            shortcut("Quick Recording", "⇧⌘R")
                            if controller.quickRecordingShortcutAvailable {
                                shortcut("Global Quick Recording", QuickRecordingShortcut.displayShortcut)
                            }
                            Text("Tab moves through available controls.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
                        }
                        .padding(14).frame(width: 250, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
            .padding(16).frame(width: 264)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            Divider()
            if let meeting = selected {
                MeetingDetail(meeting: meeting, controller: controller, tab: $tab, contentFocused: $detailFocused, scrollTarget: detailScrollTarget)
                    .id(meeting.id)
            } else {
                ContentUnavailableView(searchText.isEmpty ? "No meetings yet" : "No matching meetings",
                                       systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                                       description: Text(searchText.isEmpty ? "Record a meeting or import an audio file." : "Try another search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 650, minHeight: 460)
        .background(LibraryKeyMonitor(handle: handleKey).frame(width: 0, height: 0))
        .onAppear {
            if selection == nil { selection = controller.meetings.first?.id }
        }
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
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
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

    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11))
            Spacer(minLength: 4)
            Text(keys).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func statusColor(_ status: String) -> Color { status == "failed" ? .red : status == "waiting_for_limit" ? .orange : status == "complete" || status == "transcribed" ? .green : .secondary }
    private func meetingDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
}
struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var controller: CatetController
    @Binding var tab: Int
    @Binding var contentFocused: Bool
    fileprivate let scrollTarget: LibraryScrollTarget
    @ViewState private var outputs: LoadedOutputs?
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
        hasTranscript && meeting.status != "transcribing" && meeting.status != "summarizing"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(meeting.title).font(.system(size: 22, weight: .semibold)).lineLimit(2).help(meeting.title)
                    Text("\(meetingDate(meeting.created_at)) · \(meeting.statusLabel)")
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
                } else if meeting.status == "failed" && !hasTranscript {
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
                if outputs == nil {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == 0 { transcriptOutput }
                else { momOutput }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting-detail-\(meeting.id)")
            .simultaneousGesture(TapGesture().onEnded { contentFocused = true })
            .task(id: OutputRequest(directory: meeting.directory, status: meeting.status)) {
                await loadOutputs()
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if transcriptSegments.isEmpty {
                    Text(transcript.isEmpty ? "No transcript yet." : transcript)
                        .font(.system(size: 14)).lineSpacing(5)
                        .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                } else {
                    ForEach(transcriptSegments.indices, id: \.self) { index in
                        let segment = transcriptSegments[index]
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(shortTimestamp(segment.start))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .leading)
                            Text(segment.text).font(.system(size: 14)).lineSpacing(5)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
            .padding(20)
            .background(ScrollViewCapture(target: scrollTarget).frame(width: 0, height: 0))
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
    }
    private var momOutput: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if mom.isEmpty {
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
    private struct TranscriptSegment: Decodable, Sendable { let start: TimeInterval; let text: String }
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
    }
    private func shortTimestamp(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    private func meetingDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
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
        outputs = loaded
    }

    nonisolated private static func readOutputs(in directory: URL) throws -> LoadedOutputs {
        try Task.checkCancellation()
        let segments = (try? JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json"))))?.segments.filter {
            $0.start.isFinite && $0.start >= 0 && $0.start < Double(Int.max) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        try Task.checkCancellation()
        let transcript = segments.isEmpty ? (try? String(contentsOf: directory.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? "" : ""
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
        return LoadedOutputs(transcript: transcript, mom: mom, segments: segments, minutes: minutes)
    }
}

extension CatetController {
    func beginRecordingFlow() {
        guard !isRecording else { showLibrary(); return }
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
        guard !isRecording else { return }
        didOfferMicOnly = false
        recordingFailure = nil; recordingReady = false; pendingRecordingStop = false
        processAfterRecordingStops = true
        do {
            let meeting = try store.newMeeting(title: "Meeting \(DateFormatter.catet.string(from: Date()))", generateMoM: generateMoM)
            meetings.insert(meeting, at: 0); currentRecordingID = meeting.id; recordingStartedAt = nil
            recorder.start(directory: meeting.directory, includeSystemAudio: includeSystemAudio) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.currentRecordingID == meeting.id else { return }
                    self.recordingReady = true
                    if case .failure(let error) = result {
                        self.recordingFailure = error.localizedDescription
                        self.statusMessage = error.localizedDescription
                    }
                    if self.pendingRecordingStop || self.recordingFailure != nil { self.stopRecording() }
                }
            }
            recordingReady = true
        } catch { reportError(error) }
    }
}
