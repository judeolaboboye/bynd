// Guide: a free, Clicky-style helper. Inspired by Clicky (Farza, MIT, github.com/farzaa/clicky).
// Ask by voice or text about what's on screen; it answers, says it out loud, and can point at things.
// Thinks with Claude Code on your own plan (`claude -p`, the same way Bynd writes meeting notes),
// listens with Bynd's on-device speech, and talks with the Mac's built-in voice.
// No API keys, no AssemblyAI, no ElevenLabs, no Cloudflare.

import AppKit
import AVFoundation
import SwiftUI

struct GuideMessage: Identifiable, Equatable {
    let id = UUID()
    let fromYou: Bool
    let text: String
}

@MainActor
final class GuideModel: ObservableObject {
    static let shared = GuideModel()

    @Published private(set) var messages: [GuideMessage] = []
    @Published private(set) var busy = false
    @Published private(set) var listening = false
    @Published var lookAtScreen = UserDefaults.standard.object(forKey: "guide.screen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lookAtScreen, forKey: "guide.screen") }
    }
    @Published var speak = UserDefaults.standard.object(forKey: "guide.speak") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speak, forKey: "guide.speak"); if !speak { voice.stopSpeaking(at: .immediate) } }
    }
    private let voice = AVSpeechSynthesizer()

    /// Right ⌥ + G, or the mic button: start listening; again: send what you said.
    func toggleListening() {
        if listening {
            listening = false
            Task {
                let heard = await DictationService.shared.stop()
                let q = heard.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { ask(q) }
            }
        } else {
            guard !busy else { return }
            voice.stopSpeaking(at: .immediate)
            listening = true
            DictationService.shared.start()
        }
    }

    func clear() { messages = []; voice.stopSpeaking(at: .immediate) }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        messages.append(GuideMessage(fromYou: true, text: q))
        guard let claude = NoteWriters.shared.paths[.claude], !claude.isEmpty else {
            messages.append(GuideMessage(fromYou: false, text: "Guide needs Claude Code on this Mac. Install it, then in Terminal run `claude` and /login once."))
            return
        }
        busy = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bynd-guide-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var screen: (size: CGSize, origin: CGPoint)?
        if lookAtScreen { screen = Self.captureScreen(into: dir.appendingPathComponent("screen.png")) }
        let history = messages.dropLast().suffix(6).map { ($0.fromYou ? "Jude: " : "Guide: ") + $0.text }.joined(separator: "\n")
        let prompt = Self.prompt(question: q, history: history, screen: screen?.size)
        Task.detached {
            let answer = Self.runClaude(path: claude, prompt: prompt, cwd: dir)
            try? FileManager.default.removeItem(at: dir)
            await MainActor.run { self.finish(answer, screen: screen) }
        }
    }

    private func finish(_ answer: Result<String, GuideError>, screen: (size: CGSize, origin: CGPoint)?) {
        busy = false
        switch answer {
        case .failure(let e):
            messages.append(GuideMessage(fromYou: false, text: e.message))
        case .success(let raw):
            let (text, point) = Self.parse(raw)
            messages.append(GuideMessage(fromYou: false, text: text))
            if speak { voice.speak(AVSpeechUtterance(string: text)) }
            if let p = point, let s = screen { GuidePointer.show(at: CGPoint(x: s.origin.x + p.x, y: s.origin.y + p.y), label: p.label) }
        }
    }

    // MARK: Pieces

    struct GuideError: Error { let message: String }

    static func prompt(question: String, history: String, screen: CGSize?) -> String {
        var s = """
        You are Guide, a friendly helper that lives next to Jude's cursor on his Mac. He is not very technical.
        Answer in plain, short sentences that sound natural read aloud (at most 4 sentences, no markdown, no lists).
        """
        if let screen {
            s += """

            A screenshot of his screen right now is in ./screen.png (read it). It is \(Int(screen.width)) by \(Int(screen.height)) points, origin at the top-left.
            If pointing at something on screen would help, end your answer with one extra line exactly like:
            POINT <x> <y> <short label>
            using points on that screenshot. Otherwise don't add that line.
            """
        }
        if !history.isEmpty { s += "\n\nThe conversation so far:\n\(history)" }
        s += "\n\nJude asks: \(question)"
        return s
    }

    struct Point: Equatable { let x: CGFloat; let y: CGFloat; let label: String }

    /// Splits the spoken answer from an optional trailing "POINT x y label" line.
    nonisolated static func parse(_ raw: String) -> (String, Point?) {
        var lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var point: Point?
        if let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("POINT ") }) {
            let parts = lines[i].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3).map(String.init)
            if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                point = Point(x: x, y: y, label: parts.count > 3 ? parts[3] : "")
            }
            lines.remove(at: i)
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), point)
    }

    /// The display under the pointer, saved as a PNG. Returns its size and top-left (global, top-left origin).
    static func captureScreen(into url: URL) -> (size: CGSize, origin: CGPoint)? {
        let (id, bounds) = RecorderController.displayUnderMouse()
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        let index = (ids.prefix(Int(count)).firstIndex(of: id) ?? 0) + 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-D", String(index), url.path]
        try? p.run(); p.waitUntilExit()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (bounds.size, bounds.origin)
    }

    /// `claude -p` on Jude's own plan: may only read the screenshot in its folder.
    nonisolated static func runClaude(path: String, prompt: String, cwd: URL) -> Result<String, GuideError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-p", prompt, "--allowedTools", "Read", "--model", "sonnet", "--output-format", "json"]
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE") || key == "ANTHROPIC_BASE_URL" || key == "ANTHROPIC_AUTH_TOKEN" { env[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.claude/local",
                       env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(GuideError(message: "Couldn\u{2019}t start Claude Code: \(error.localizedDescription)")) }
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit(); timeout.cancel()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = json["result"] as? String {
            if json["is_error"] as? Bool == true {
                let l = result.lowercased()
                if l.contains("login") || l.contains("api key") {
                    return .failure(GuideError(message: "Claude Code isn\u{2019}t signed in. Open Terminal, run `claude`, type /login, then ask again."))
                }
                return .failure(GuideError(message: String(result.prefix(200))))
            }
            return .success(result)
        }
        let why = errText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(GuideError(message: why.isEmpty ? "Claude Code didn\u{2019}t answer (exit \(p.terminationStatus))." : String(why.suffix(200))))
    }
}

/// A yellow pointer and label that appears on screen where Guide is pointing, for a few seconds.
@MainActor
enum GuidePointer {
    private static var window: NSWindow?

    /// `p` is a global point with a top-left origin (like the screenshot).
    static func show(at p: CGPoint, label: String) {
        window?.orderOut(nil)
        let mainH = NSScreen.screens.first?.frame.maxY ?? 0
        let size = CGSize(width: 260, height: 90)
        let appKit = CGPoint(x: p.x, y: mainH - p.y)
        let w = NSWindow(contentRect: CGRect(x: appKit.x - 18, y: appKit.y - size.height + 18, width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: PointerView(label: label))
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if window === w { w.orderOut(nil); window = nil } }
    }

    private struct PointerView: View {
        let label: String
        @State private var bob = false
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "arrowtriangle.up.fill").rotationEffect(.degrees(-45))
                    .font(.system(size: 26)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.3))
                    .shadow(radius: 3).offset(x: bob ? 4 : 0, y: bob ? 4 : 0)
                if !label.isEmpty {
                    Text(label).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { bob = true } }
        }
    }
}

/// The Guide section.
struct GuideView: View {
    @ObservedObject private var g = GuideModel.shared
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotionHeader(icon: .symbol("questionmark.bubble"), title: "Guide",
                         description: "Ask how to do anything on your Mac. Guide looks at your screen, answers out loud and points at things. Press right \u{2325} + G to ask by voice from any app.") {
                EmptyView()
            } below: {
                HStack(spacing: 16) {
                    Toggle("Look at my screen", isOn: $g.lookAtScreen)
                    Toggle("Say answers out loud", isOn: $g.speak)
                    Spacer()
                    if !g.messages.isEmpty { Button("Clear") { g.clear() } }
                }
                .padding(.top, 12)
            }
            .pageColumn()
            .padding(.top, 36)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if g.messages.isEmpty {
                            Text("Try: \u{201C}How do I change my wallpaper?\u{201D} or \u{201C}Where is the export button here?\u{201D}")
                                .font(DF.font(15)).foregroundStyle(DF.muted).padding(.top, 20)
                        }
                        ForEach(g.messages) { m in
                            Text(m.text).font(DF.font(15)).textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(m.fromYou ? DF.canvas : DF.paper, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DF.line))
                                .frame(maxWidth: .infinity, alignment: m.fromYou ? .trailing : .leading)
                                .id(m.id)
                        }
                        if g.busy { ProgressView().controlSize(.small).padding(.top, 4) }
                    }
                    .pageColumn()
                    .padding(.vertical, 16)
                }
                .onChange(of: g.messages) { _, list in if let last = list.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }

            HStack(spacing: 8) {
                Button { g.toggleListening() } label: {
                    Image(systemName: g.listening ? "stop.circle.fill" : "mic.circle.fill").font(.system(size: 24))
                        .foregroundStyle(g.listening ? .red : DF.ink)
                }
                .buttonStyle(.plain).help(g.listening ? "Send what you said" : "Ask by voice")
                TextField(g.listening ? "Listening\u{2026} press again to send" : "Ask Guide anything", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { g.ask(text); text = "" }
                    .disabled(g.listening)
                Button("Ask") { g.ask(text); text = "" }.disabled(text.isEmpty || g.busy)
            }
            .pageColumn()
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DF.paper)
    }
}
