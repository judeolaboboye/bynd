import AppKit
import SwiftUI

/// Everything about finished recordings that matters for b-roll:
///  - Parts: next to each recording, the screen, the camera and the audio as separate files.
///  - Storage: how much space recordings use; past the limit (20 GB), what could go (oldest first, never "Keep").
///  - Google Drive: copy recordings into a Drive folder (Google Drive for desktop does the upload), capped at 50 GB.
@MainActor
final class RecordingLibrary: ObservableObject {
    static let shared = RecordingLibrary()

    static let storageLimit: Int64 = 20 * 1_073_741_824
    static let driveLimit: Int64 = 50 * 1_073_741_824

    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var kept: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "library.kept") ?? [])
    @Published var autoUpload = UserDefaults.standard.bool(forKey: "library.autoUpload") {
        didSet { UserDefaults.standard.set(autoUpload, forKey: "library.autoUpload") }
    }
    @Published var driveSubfolder = UserDefaults.standard.string(forKey: "library.driveFolder") ?? "Bynd" {
        didSet { UserDefaults.standard.set(driveSubfolder, forKey: "library.driveFolder") }
    }
    @Published private(set) var driveUsedBytes: Int64 = 0
    @Published private(set) var uploading: Set<String> = []
    @Published var lastMessage: String?

    nonisolated static var captures: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Bynd", isDirectory: true)
    }
    nonisolated static var projects: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bynd/Recordings", isDirectory: true)
    }

    // MARK: Parts (screen / camera / audio separately)

    /// The folder next to a recording that holds its parts: "capture-<stamp> parts".
    nonisolated static func partsFolder(for raw: URL) -> URL {
        raw.deletingLastPathComponent().appendingPathComponent(raw.deletingPathExtension().lastPathComponent + " parts", isDirectory: true)
    }

    /// Copies the take's separate tracks next to the finished recording. On APFS a copy is a clone,
    /// so this takes no extra disk space until one of the files is changed.
    nonisolated static func saveParts(takeDirectory dir: URL, camera: URL?, raw: URL) {
        let fm = FileManager.default
        let out = partsFolder(for: raw)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let pairs: [(URL?, String)] = [
            (dir.appending(path: "screen.mov"), "screen only.mov"),
            (camera, "camera only.mov"),
            (dir.appending(path: "mic.mov"), "voice (mic).mov"),
            (fm.fileExists(atPath: dir.appending(path: "system-only.mov").path) ? dir.appending(path: "system-only.mov") : nil, "mac sound.mov"),
        ]
        for (src, name) in pairs {
            guard let src, fm.fileExists(atPath: src.path) else { continue }
            let dst = out.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        DFLog.log("library", "saved parts for \(raw.lastPathComponent)")
    }

    nonisolated static func parts(for raw: URL) -> [URL] {
        let dir = partsFolder(for: raw)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Storage

    struct Item: Identifiable, Hashable {
        var id: String { stem }
        let stem: String          // "capture-2026-11-23-10.00.00"
        let date: Date
        let bytes: Int64
        let files: [URL]
    }

    /// One entry per recording or screenshot, everything with the same stem together (videos, parts, transcript).
    nonisolated static func items() -> [Item] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: captures, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var groups: [String: [URL]] = [:]
        for f in all where f.lastPathComponent.hasPrefix("capture-") {
            // "capture-" + "yyyy-MM-dd-HH.mm.ss" (the time has dots, so cut by length, not at the first dot).
            let name = f.lastPathComponent
            guard name.count >= 27 else { continue }
            let stem = String(name.prefix(27))
            groups[stem, default: []].append(f)
        }
        return groups.map { stem, files in
            let date = files.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.min() ?? .distantPast
            return Item(stem: stem, date: date, bytes: files.reduce(0) { $0 + size(of: $1) }, files: files)
        }.sorted { $0.date < $1.date }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    func refresh() {
        Task.detached {
            let used = Self.size(of: Self.captures) + Self.size(of: Self.projects)
            let drive = Self.driveFolderURL().map(Self.size(of:)) ?? 0
            await MainActor.run { self.usedBytes = used; self.driveUsedBytes = drive }
        }
    }

    var overLimit: Bool { usedBytes > Self.storageLimit }

    /// What could be deleted to get back under the limit: oldest first, never anything marked Keep.
    func suggestions() -> [Item] {
        guard overLimit else { return [] }
        var excess = usedBytes - Self.storageLimit
        var out: [Item] = []
        for item in Self.items() where !kept.contains(item.stem) {
            guard excess > 0 else { break }
            out.append(item); excess -= item.bytes
        }
        return out
    }

    func isKept(_ stem: String) -> Bool { kept.contains(stem) }
    func setKept(_ stem: String, _ on: Bool) {
        if on { kept.insert(stem) } else { kept.remove(stem) }
        UserDefaults.standard.set(Array(kept), forKey: "library.kept")
    }

    /// Moves a recording (all its files) to the Trash.
    func trash(_ items: [Item]) {
        for i in items { for f in i.files { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) } }
        refresh()
    }

    // MARK: Google Drive (through Google Drive for desktop)

    /// "My Drive" of the first Google account signed in to Google Drive for desktop.
    nonisolated static func myDrive() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let accounts = ((try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
        for a in accounts {
            for name in ["My Drive", "Meine Ablage", "Mon Drive", "Mi unidad"] {
                let u = a.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    nonisolated static func driveFolderURL() -> URL? {
        guard let root = myDrive() else { return nil }
        let sub = UserDefaults.standard.string(forKey: "library.driveFolder") ?? "Bynd"
        return root.appendingPathComponent(sub.isEmpty ? "Bynd" : sub, isDirectory: true)
    }

    var driveAvailable: Bool { Self.myDrive() != nil }

    /// Copies a recording's files (and its parts) into the Drive folder. Google Drive for desktop uploads them.
    func upload(_ stem: String) {
        guard let dest = Self.driveFolderURL() else {
            lastMessage = "Google Drive for desktop isn\u{2019}t set up yet."; return
        }
        guard !uploading.contains(stem) else { return }
        let files = Self.items().first { $0.stem == stem }?.files ?? []
        guard !files.isEmpty else { return }
        uploading.insert(stem)
        Task.detached {
            let fm = FileManager.default
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let need = files.reduce(Int64(0)) { $0 + Self.size(of: $1) }
            let have = Self.size(of: dest)
            var message: String
            if have + need > Self.driveLimit {
                message = "Not uploaded: the Drive folder would go over 50 GB (it has \(Self.gb(have)))."
            } else {
                for f in files {
                    let target = dest.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: target)
                    try? fm.copyItem(at: f, to: target)
                }
                message = "Copied \(Self.gb(need)) to Google Drive \u{2192} \(dest.lastPathComponent). Drive uploads it in the background."
            }
            await MainActor.run {
                self.uploading.remove(stem)
                self.lastMessage = message
                self.refresh()
            }
        }
    }

    nonisolated static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
}

/// Storage and Google Drive, shown in the Tasks section.
struct LibraryCards: View {
    @ObservedObject private var lib = RecordingLibrary.shared
    @State private var confirm: [RecordingLibrary.Item] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Storage").font(DF.font(13, .semibold)).foregroundStyle(DF.muted).padding(.top, 26).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recordings and screenshots use \(RecordingLibrary.gb(lib.usedBytes)) of the 20 GB limit")
                    Spacer()
                    Button("Show folder") { NSWorkspace.shared.open(RecordingLibrary.captures) }
                }
                ProgressView(value: min(Double(lib.usedBytes) / Double(RecordingLibrary.storageLimit), 1))
                    .tint(lib.overLimit ? .red : DF.ink)
                if lib.overLimit {
                    let s = lib.suggestions()
                    Text("Over 20 GB. These are the oldest recordings not marked Keep (\(RecordingLibrary.gb(s.reduce(0) { $0 + $1.bytes }))):")
                        .font(DF.font(13)).foregroundStyle(.orange)
                    ForEach(s) { i in
                        HStack {
                            Text(i.stem.replacingOccurrences(of: "capture-", with: "")).font(DF.font(13))
                            Spacer()
                            Text(RecordingLibrary.gb(i.bytes)).font(DF.font(13)).foregroundStyle(DF.muted)
                            Button("Keep") { lib.setKept(i.stem, true) }.controlSize(.small)
                        }
                    }
                    Button("Move these to the Trash\u{2026}") { confirm = s }.disabled(s.isEmpty)
                } else {
                    Text("Bynd checks this for you. Past 20 GB it lists the oldest recordings you haven\u{2019}t marked Keep, and deletes only when you say so.")
                        .font(DF.font(13)).foregroundStyle(DF.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
            .dfCard()

            Text("Google Drive").font(DF.font(13, .semibold)).foregroundStyle(DF.muted).padding(.top, 26).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                if lib.driveAvailable {
                    HStack {
                        Text("Copies go to My Drive \u{2192}")
                        TextField("Bynd", text: $lib.driveSubfolder).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    Text("Using \(RecordingLibrary.gb(lib.driveUsedBytes)) of the 50 GB limit for this folder.").font(DF.font(13)).foregroundStyle(DF.muted)
                    Toggle("Upload each task recording when it finishes", isOn: $lib.autoUpload)
                    Text("Or use \u{201C}Upload to Drive\u{201D} on any task below. Google Drive for desktop does the uploading.")
                        .font(DF.font(13)).foregroundStyle(DF.faint)
                } else {
                    Text("Install Google\u{2019}s free \u{201C}Google Drive for desktop\u{201D} and sign in once. Bynd then copies your recordings into a Drive folder you pick (up to 50 GB), and Drive uploads them.")
                        .font(DF.font(14)).fixedSize(horizontal: false, vertical: true)
                    Button("Get Google Drive for desktop") {
                        NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!)
                    }
                    Text("A free Google account has 15 GB in total; a 50 GB folder needs a Google One plan.")
                        .font(DF.font(13)).foregroundStyle(DF.faint)
                }
                if let m = lib.lastMessage { Text(m).font(DF.font(13)).foregroundStyle(DF.muted) }
            }
            .dfCard()
        }
        .onAppear { lib.refresh() }
        .alert("Move \(confirm.count) recording\(confirm.count == 1 ? "" : "s") to the Trash?", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } })) {
            Button("Move to Trash", role: .destructive) { lib.trash(confirm); confirm = [] }
            Button("Cancel", role: .cancel) { confirm = [] }
        } message: { Text("Their videos, parts and transcripts go to the Trash, where you can still get them back.") }
    }
}
