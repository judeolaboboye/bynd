import AppKit
import AVFoundation
import SwiftUI

/// One task you worked on while Bynd recorded. Its videos are the captures made during it.
struct TaskSession: Codable, Identifiable, Equatable {
    /// Same folder as CaptureService.folder (~/Pictures/Bynd), readable from any thread.
    nonisolated static var capturesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Bynd", isDirectory: true)
    }

    var id = UUID()
    var title: String
    var start: Date
    var end: Date?

    /// Raw recordings (not the polished copies) saved while this task ran.
    var recordings: [URL] {
        let fm = FileManager.default
        let until = (end ?? Date()).addingTimeInterval(30 * 60)   // polishing can finish a while later
        let files = (try? fm.contentsOfDirectory(at: TaskSession.capturesFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "mp4" && !$0.lastPathComponent.contains(".polished")
        }.filter {
            let d = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d >= start.addingTimeInterval(-60) && d <= until
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Tasks: work on something while Bynd records your screen and your face (no call, nobody else), to pick
/// stills and clips for b-roll later.
///
/// You choose the events: switch them on in the calendar panel. When one starts, Bynd asks
/// "Are you working?"; yes records until the event ends (or until you stop it with fn ⌘). Events you
/// don't switch on are left alone, and once you stop or skip one it won't ask again that day.
@MainActor
final class TaskRecording: ObservableObject {
    static let shared = TaskRecording()

    @Published private(set) var recordingFor: CalEvent?
    @Published private(set) var lastAsked: String?
    @Published private(set) var sessions: [TaskSession] = TaskRecording.loadSessions()
    @Published private(set) var current: TaskSession?

    private var timer: Timer?
    private var watch: Timer?
    private var asked = Set<String>()   // events already asked about today

    // MARK: Switched-on events

    /// Calendar events switched on in the Tasks side panel.
    static let autoKey = "taskRecordIDs"
    static func autoIDs() -> Set<String> {
        Set((UserDefaults.standard.string(forKey: autoKey) ?? "").split(separator: "|").map(String.init))
    }
    static func setAuto(_ id: String, _ on: Bool) {
        var ids = autoIDs()
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.joined(separator: "|"), forKey: autoKey)
    }

    /// A switched-on event happening now (the most recently started, not skipped or stopped today).
    func currentAutoTask(now: Date = Date()) -> CalEvent? {
        let ids = Self.autoIDs()
        guard !ids.isEmpty, CalendarStore.shared.authorized else { return nil }
        return CalendarStore.shared.events(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(60))
            .filter { !$0.isAllDay && $0.start <= now && $0.end > now && ids.contains($0.id) && !CalendarStore.shared.isSkipped($0) }
            .max { $0.start < $1.start }
    }

    /// Your switched-on task events in the next 7 days, for the Tasks section.
    func upcoming(now: Date = Date()) -> [CalEvent] {
        let ids = Self.autoIDs()
        guard !ids.isEmpty, CalendarStore.shared.authorized else { return [] }
        return CalendarStore.shared.events(from: now, to: now.addingTimeInterval(7 * 86_400))
            .filter { !$0.isAllDay && ids.contains($0.id) }
            .sorted { $0.start < $1.start }
    }

    // MARK: Sessions (saved list of tasks)

    private static var sessionsFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bynd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }
    private static func loadSessions() -> [TaskSession] {
        guard let d = try? Data(contentsOf: sessionsFile) else { return [] }
        return (try? JSONDecoder().decode([TaskSession].self, from: d)) ?? []
    }
    private func saveSessions() {
        if let d = try? JSONEncoder().encode(sessions) { try? d.write(to: Self.sessionsFile, options: .atomic) }
    }

    func rename(_ s: TaskSession, to title: String) {
        guard let i = sessions.firstIndex(of: s) else { return }
        sessions[i].title = title; saveSessions()
    }

    /// Forget a task. With `files`, its recordings (raw, polished, transcript, parts) go to the Trash too.
    func remove(_ s: TaskSession, files: Bool) {
        if files {
            for raw in s.recordings {
                let stem = raw.deletingPathExtension().lastPathComponent
                let all = (try? FileManager.default.contentsOfDirectory(at: TaskSession.capturesFolder, includingPropertiesForKeys: nil)) ?? []
                for f in all where f.lastPathComponent.hasPrefix(stem) { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) }
            }
        }
        sessions.removeAll { $0.id == s.id }; saveSessions()
    }

    /// Was this recording made during a task?
    func isTaskRecording(_ raw: URL) -> Bool { sessions.contains { $0.recordings.contains(raw) } }

    // MARK: Checking the calendar

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in TaskRecording.shared.check() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { TaskRecording.shared.check() }
    }

    func check() {
        // Stop at the end of the event we started for.
        if let e = recordingFor, Date() >= e.end {
            if RecorderController.shared.isRecording { RecorderController.shared.stop() }
        }
        guard recordingFor == nil, current == nil, !RecorderController.shared.isRecording,
              !MeetingService.shared.isRecording else { return }
        // Only events you switched on; when one starts, ask "Are you working?".
        guard let e = currentAutoTask() else { return }
        let key = CalendarStore.skipKey(e)
        guard !asked.contains(key) else { return }
        asked.insert(key)
        ask(about: e)
    }

    private func ask(about e: CalEvent) {
        lastAsked = e.title
        let alert = NSAlert()
        alert.messageText = "Are you working?"
        alert.informativeText = "It\u{2019}s \u{201C}\(e.title)\u{201D} until \(e.end.formatted(date: .omitted, time: .shortened)). Bynd can record your screen and your face until then. Stop any time with fn \u{2318}."
        alert.addButton(withTitle: "Yes, record")
        alert.addButton(withTitle: "Not this one")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            CalendarStore.shared.skip(e)      // "Not this one": move on to the next event
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.check() }
            return
        }
        begin(for: e)
    }

    // MARK: Recording

    /// Screen + camera + mic, whole screen under the pointer.
    func begin(for e: CalEvent?, title: String? = nil) {
        let r = RecorderController.shared
        guard !r.isRecording else { return }
        let session = TaskSession(title: title ?? e?.title ?? "Task \(Date().formatted(date: .abbreviated, time: .shortened))", start: Date())
        current = session
        recordingFor = e
        sessions.insert(session, at: 0); saveSessions()
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in TaskRecording.shared.watchRecorder() }
        }
        r.mode = .screen
        if r.cameraID == nil { r.cameraID = AVCaptureDevice.default(for: .video)?.uniqueID }
        r.open()
        // Give the camera a moment to start, then record straight away (no bar to click).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            r.record()
            DFLog.log("task", "task recording started: \(session.title)")
        }
    }

    /// Ends the task when the recording stops (by hand, fn ⌘, or at the end of the event).
    private func watchRecorder() {
        guard let c = current else { watch?.invalidate(); watch = nil; return }
        if Date().timeIntervalSince(c.start) > 5, !RecorderController.shared.isRecording {
            // Stopped: that calendar event is done for today, so it won't ask again.
            if let e = recordingFor { CalendarStore.shared.skip(e) }
            if let i = sessions.firstIndex(where: { $0.id == c.id }) { sessions[i].end = Date(); saveSessions() }
            current = nil
            recordingFor = nil
            watch?.invalidate(); watch = nil
        }
    }

    func stopTask() {
        if RecorderController.shared.isRecording { RecorderController.shared.stop() }
    }
}

// MARK: - Views

/// The Tasks section with today's calendar on the right (toggle it with the sidebar button, like Meetings).
struct TasksView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            TasksMain().frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.sidePanelOpen {
                Rectangle().fill(DF.line).frame(width: 1)
                TodayTasks().frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DF.paper)
    }
}

/// Today's calendar, each event with a switch: on = Bynd asks "Are you working?" when it starts.
private struct TodayTasks: View {
    @EnvironmentObject var calendars: CalendarStore
    @State private var ids = TaskRecording.autoIDs()

    var body: some View {
        let events = calendars.events(on: Date()).filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today").font(DF.serif(20))
                Spacer()
                PanelCloseButton()
            }
            .padding(.top, 20)
            Text(calendars.anyConnected ? "Switch on the ones you want: Bynd asks \u{201C}Are you working?\u{201D} when they start" : "Connect your calendar to see today\u{2019}s events")
                .font(DF.font(12)).foregroundStyle(DF.muted).padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
            if !calendars.anyConnected {
                SecondaryButton(title: "Allow calendar access", symbol: "calendar") { Task { await calendars.requestAccess() } }
            } else if events.isEmpty {
                Text("Nothing on your calendar today.").font(DF.font(13)).foregroundStyle(DF.faint)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(events) { e in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(e.end < Date() ? DF.checkbox : DF.honeyDeep).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(DF.font(13, .semibold)).lineLimit(1)
                                Text("\(e.start.formatted(date: .omitted, time: .shortened)) \u{2013} \(e.end.formatted(date: .omitted, time: .shortened))")
                                    .font(DF.font(12)).foregroundStyle(DF.muted)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { ids.contains(e.id) }, set: { v in
                                TaskRecording.setAuto(e.id, v); ids = TaskRecording.autoIDs()
                            }))
                            .toggleStyle(.df)
                            .help("Ask \u{201C}Are you working?\u{201D} when this starts, and record it as a task")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(DF.canvas)
    }
}

/// The main Tasks page: do your work while Bynd records your screen and face, for b-roll later.
private struct TasksMain: View {
    @ObservedObject private var tr = TaskRecording.shared
    @ObservedObject private var recorder = RecorderController.shared
    @EnvironmentObject var calendars: CalendarStore
    @State private var newTitle = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NotionHeader(icon: .symbol("record.circle"), title: "Tasks",
                             description: "Work on something while Bynd records your screen and your face. No call, nobody else. Afterwards pick stills and clips from it for b-roll.") {
                    EmptyView()
                } below: { EmptyView() }

                // Now
                VStack(alignment: .leading, spacing: 10) {
                    if let c = tr.current {
                        HStack {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text("Recording \u{201C}\(c.title)\u{201D}").font(DF.font(15, .semibold))
                            Spacer()
                            Button("Stop task") { tr.stopTask() }.keyboardShortcut(.defaultAction)
                        }
                    } else {
                        HStack {
                            TextField("What are you working on?", text: $newTitle).textFieldStyle(.roundedBorder)
                                .onSubmit(startNow)
                            Button("Start task") { startNow() }.disabled(recorder.isRecording)
                        }
                        Text("Records the whole screen with your camera and mic. Stop with the button here or fn \u{2318}.")
                            .font(DF.font(13)).foregroundStyle(DF.faint)
                    }
                }
                .dfCard().padding(.top, 22)

                // Your task events
                Text("Your task events").font(DF.font(13, .semibold)).foregroundStyle(DF.muted).padding(.top, 26).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Switch events on in today\u{2019}s calendar on the right (the sidebar button at the top shows it). When one starts, Bynd asks \u{201C}Are you working?\u{201D}; say yes and it records your screen and face until the event ends. Events you don\u{2019}t switch on are left alone, and once you stop or skip one it won\u{2019}t ask again today.")
                        .font(DF.font(13)).foregroundStyle(DF.faint).fixedSize(horizontal: false, vertical: true)
                    if !calendars.authorized {
                        Text("Calendar access is off. Turn it on in Settings \u{2192} Calendars.").font(DF.font(13)).foregroundStyle(.orange)
                    } else {
                        let next = tr.upcoming().prefix(6)
                        if next.isEmpty {
                            Text("No events switched on yet.").font(DF.font(13)).foregroundStyle(DF.faint)
                        } else {
                            ForEach(Array(next), id: \.self) { e in
                                HStack {
                                    Image(systemName: "calendar").foregroundStyle(DF.muted)
                                    Text(e.title).lineLimit(1)
                                    Spacer()
                                    Text("\(e.start.formatted(.dateTime.weekday().hour().minute())) \u{2013} \(e.end.formatted(date: .omitted, time: .shortened))")
                                        .font(DF.font(13)).foregroundStyle(DF.muted)
                                }
                            }
                        }
                    }
                }
                .dfCard()

                LibraryCards()

                // Recordings
                Text("Task recordings").font(DF.font(13, .semibold)).foregroundStyle(DF.muted).padding(.top, 26).padding(.bottom, 8)
                if tr.sessions.isEmpty {
                    Text("No tasks recorded yet.").font(DF.font(15)).foregroundStyle(DF.muted)
                } else {
                    VStack(spacing: 8) { ForEach(tr.sessions) { s in TaskRow(session: s) } }
                }
            }
            .pageColumn()
            .padding(.top, 36).padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DF.paper)
    }

    private func startNow() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        tr.begin(for: nil, title: t.isEmpty ? nil : t)
        newTitle = ""
    }
}

private struct TaskRow: View {
    let session: TaskSession
    @ObservedObject private var tr = TaskRecording.shared
    @ObservedObject private var lib = RecordingLibrary.shared
    @State private var confirmDelete = false

    var body: some View {
        let recs = session.recordings
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "record.circle").font(.system(size: 18)).foregroundStyle(DF.muted).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(DF.font(15, .semibold))
                Text([session.start.formatted(date: .abbreviated, time: .shortened),
                      session.end.map { "\(Int($0.timeIntervalSince(session.start) / 60)) min" } ?? "recording\u{2026}",
                      "\(recs.count) video\(recs.count == 1 ? "" : "s")"].joined(separator: " \u{00B7} "))
                    .font(DF.font(13)).foregroundStyle(DF.muted)
                HStack(spacing: 8) {
                    ForEach(recs, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "capture-", with: "Video ")) {
                            NSWorkspace.shared.open(url)
                        }
                        let polished = url.deletingPathExtension().appendingPathExtension("polished.mp4")
                        if FileManager.default.fileExists(atPath: polished.path) {
                            Button("Polished") { NSWorkspace.shared.open(polished) }
                        }
                    }
                    if !recs.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(recs) }
                    }
                }
                .controlSize(.small)
                ForEach(recs, id: \.self) { url in
                    let parts = RecordingLibrary.parts(for: url)
                    let stem = url.deletingPathExtension().lastPathComponent
                    HStack(spacing: 8) {
                        if !parts.isEmpty {
                            Text("Separate:").font(DF.font(12)).foregroundStyle(DF.muted)
                            ForEach(parts, id: \.self) { p in
                                Button(p.deletingPathExtension().lastPathComponent.capitalized) { NSWorkspace.shared.open(p) }
                            }
                        }
                        Spacer(minLength: 4)
                        Toggle("Keep", isOn: Binding(get: { lib.isKept(stem) }, set: { lib.setKept(stem, $0) }))
                            .toggleStyle(.checkbox).help("Never suggested for deleting when space runs low")
                        if lib.driveAvailable {
                            Button(lib.uploading.contains(stem) ? "Uploading\u{2026}" : "Upload to Drive") { lib.upload(stem) }
                                .disabled(lib.uploading.contains(stem))
                        }
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
            Menu {
                Button("Forget this task (keep videos)") { tr.remove(session, files: false) }
                Button("Delete task and its videos\u{2026}", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12)
        .background(DF.canvas, in: RoundedRectangle(cornerRadius: 8))
        .alert("Delete \u{201C}\(session.title)\u{201D} and its videos?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { tr.remove(session, files: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The videos, polished copies and transcripts go to the Trash.") }
    }
}
