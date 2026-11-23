// Circle-to-screenshot while dictating, from BetterVoice.
// The circle detector below is adapted from BetterVoice's CircleGestureDetector:
// Copyright (c) 2026 Tarun Tomar, MIT License (https://github.com/TarunTomar122/better-voice).

import AppKit
import CoreGraphics
import SwiftUI

/// Detects one closed, roughly circular pointer stroke at a time (BetterVoice's geometry checks).
struct CircleGestureDetector {
    struct Gesture: Equatable { let center: CGPoint; let radius: CGFloat }
    private struct Sample { let point: CGPoint; let time: TimeInterval }

    private var samples: [Sample] = []
    private var cooldownUntil: TimeInterval = 0
    private var waitingForExit: Gesture?
    private let window: TimeInterval = 6
    let minimumAngleDegrees: CGFloat

    init(minimumAngleDegrees: CGFloat = 340) { self.minimumAngleDegrees = min(max(minimumAngleDegrees, 300), 359) }

    mutating func reset() { samples.removeAll(keepingCapacity: true); cooldownUntil = 0; waitingForExit = nil }

    mutating func add(point: CGPoint, at time: TimeInterval) -> Gesture? {
        if let g = waitingForExit {
            guard hypot(point.x - g.center.x, point.y - g.center.y) > g.radius * 1.5 else { return nil }
            waitingForExit = nil
            samples.removeAll(keepingCapacity: true)
        }
        guard time >= cooldownUntil else { return nil }
        if let previous = samples.last, time - previous.time > 0.45 { samples.removeAll(keepingCapacity: true) }
        samples.append(Sample(point: point, time: time))
        samples.removeAll { $0.time < time - window }
        guard samples.count >= 18, let g = recognized() else { return nil }
        samples.removeAll(keepingCapacity: true)
        cooldownUntil = time + 0.65
        waitingForExit = g
        return g
    }

    private func recognized() -> Gesture? {
        guard let last = samples.last?.point else { return nil }
        for start in stride(from: samples.count - 18, through: 0, by: -1) {
            let first = samples[start].point
            guard hypot(first.x - last.x, first.y - last.y) < 160 else { continue }
            if let g = recognized(Array(samples[start...]).map(\.point)) { return g }
        }
        return nil
    }

    private func recognized(_ points: [CGPoint]) -> Gesture? {
        guard let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let w = maxX - minX, h = maxY - minY
        guard w >= 28, h >= 28, w / h > 0.45, w / h < 2.2 else { return nil }
        let c = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let d = points.map { hypot($0.x - c.x, $0.y - c.y) }
        let r = d.reduce(0, +) / CGFloat(d.count)
        guard r >= 18 else { return nil }
        let variance = d.reduce(0) { $0 + pow($1 - r, 2) } / CGFloat(d.count)
        guard sqrt(variance) / r < 0.32 else { return nil }
        guard hypot(first.x - last.x, first.y - last.y) < max(20, r * 0.65) else { return nil }
        var travel: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            var delta = atan2(b.y - c.y, b.x - c.x) - atan2(a.y - c.y, a.x - c.x)
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            travel += abs(delta)
        }
        guard travel > minimumAngleDegrees * .pi / 180, travel < 8.8 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let ratio = length / (2 * .pi * r)
        guard ratio > 0.65, ratio < 1.9 else { return nil }
        return Gesture(center: c, radius: r)
    }
}

/// Draw: while left ⌥ is held, silently follows the pointer. Each circle you draw screenshots just the
/// area you circled (with a little margin), flashes a blue ring there, saves it in Draw and puts it on the
/// clipboard. Draw never dictates and never pastes into other apps.
@MainActor
final class CircleCapture {
    static let shared = CircleCapture()

    /// Where Draw screenshots are kept (shown in the Draw section).
    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Bynd/Draw", isDirectory: true)
    }

    private var detector = CircleGestureDetector()
    private var timer: Timer?
    private var started = Date()
    private(set) var captured: [URL] = []
    private var onReleased: (() -> Void)?
    private var optionUpSince: Date?
    private var pulse: NSWindow?

    private init() {}

    /// `onReleased` runs as soon as left ⌥ is found to be up (a missed key release), so it can never get stuck.
    func start(onReleased: @escaping () -> Void) {
        stop()
        detector.reset()
        captured = []
        started = Date()
        optionUpSince = nil
        self.onReleased = onReleased
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in CircleCapture.shared.tick() }
        }
    }

    /// Stops following the pointer and returns the screenshots taken, in order.
    @discardableResult
    func finish() -> [URL] {
        let out = captured
        stop()
        return out
    }

    func stop() {
        timer?.invalidate(); timer = nil
        onReleased = nil
    }

    var isActive: Bool { timer != nil }

    private func tick() {
        // Safety: if ⌥ isn't actually held any more, treat it as released.
        if !NSEvent.modifierFlags.contains(.option) {
            if optionUpSince == nil { optionUpSince = Date() }
            if let t = optionUpSince, Date().timeIntervalSince(t) > 0.1 { let r = onReleased; stop(); r?(); return }
        } else { optionUpSince = nil }
        let p = NSEvent.mouseLocation
        if let g = detector.add(point: p, at: Date().timeIntervalSince(started)) { capture(around: g) }
    }

    /// The circled area plus a margin, as a global top-left rectangle for `screencapture -R`.
    nonisolated static func region(for g: CircleGestureDetector.Gesture, screen: CGRect, mainHeight: CGFloat) -> CGRect {
        let side = max(g.radius * 2 * 1.3, 160)
        var r = CGRect(x: g.center.x - side / 2, y: g.center.y - side / 2, width: side, height: side)
        r = r.intersection(screen)                       // keep it on the screen it was drawn on
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)   // AppKit → top-left
    }

    private func capture(around g: CircleGestureDetector.Gesture) {
        let screen = NSScreen.screens.first { $0.frame.contains(g.center) }?.frame ?? NSScreen.main?.frame ?? .zero
        let mainH = NSScreen.screens.first?.frame.maxY ?? 0
        let r = Self.region(for: g, screen: screen, mainHeight: mainH)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.folder.appendingPathComponent("Draw \(f.string(from: Date())) \(captured.count + 1).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path]
        try? p.run()
        p.waitUntilExit()
        guard FileManager.default.fileExists(atPath: url.path) else {
            DFLog.log("circle", "screenshot failed (Screen Recording allowed?)")
            return
        }
        captured.append(url)
        // On the clipboard too, in case you want to paste it somewhere yourself.
        if let image = NSImage(contentsOf: url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
        NSSound(named: "Tink")?.play()
        showPulse(at: g)
        DFLog.log("circle", "captured \(url.lastPathComponent) \(Int(r.width))x\(Int(r.height))")
    }

    /// A short blue ring where you circled, so you know it was captured.
    private func showPulse(at g: CircleGestureDetector.Gesture) {
        pulse?.orderOut(nil)
        let side = g.radius * 2 + 40
        let w = NSWindow(contentRect: CGRect(x: g.center.x - side / 2, y: g.center.y - side / 2, width: side, height: side),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: PulseRing(diameter: g.radius * 2))
        w.orderFrontRegardless()
        pulse = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.pulse === w { w.orderOut(nil); self?.pulse = nil }
        }
    }
}

private struct PulseRing: View {
    let diameter: CGFloat
    @State private var grow = false
    var body: some View {
        Circle()
            .stroke(Color(red: 0.25, green: 0.55, blue: 1), lineWidth: 3)
            .frame(width: diameter, height: diameter)
            .scaleEffect(grow ? 1.25 : 1)
            .opacity(grow ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { grow = true } }
    }
}

/// What you wrote about each Draw screenshot, kept next to them in Draw/descriptions.json.
enum DrawNotes {
    static var file: URL { CircleCapture.folder.appendingPathComponent("descriptions.json") }
    static func all() -> [String: String] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }
    static func set(_ text: String, for name: String) {
        var a = all()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { a[name] = nil } else { a[name] = t }
        try? FileManager.default.createDirectory(at: CircleCapture.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: file, options: .atomic) }
    }
}
