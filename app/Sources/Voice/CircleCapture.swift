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

/// While left ⌥ is held: follows the pointer, and each circle drawn screenshots the display under it.
/// Shows a blue trail and a pulse where each capture happened.
@MainActor
final class CircleCapture {
    static let shared = CircleCapture()

    /// Where Draw screenshots are kept (shown in the Draw section).
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Bynd/Draw", isDirectory: true)
    }

    private var detector = CircleGestureDetector()
    private var timer: Timer?
    private var started = Date()
    private(set) var captured: [URL] = []
    private var overlays: [NSWindow] = []
    private let trail = TrailModel()

    private init() {}

    func start() {
        stop()
        detector.reset()
        captured = []
        started = Date()
        trail.points = []
        showTrail()
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
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let t = Date().timeIntervalSince(started)
        trail.add(p, at: t)
        if let g = detector.add(point: p, at: t) { capture(around: g) }
    }

    private func capture(around g: CircleGestureDetector.Gesture) {
        let screens = NSScreen.screens
        let index = screens.firstIndex { $0.frame.contains(g.center) } ?? 0
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.folder.appendingPathComponent("Draw \(f.string(from: Date())) \(captured.count + 1).png")
        // Hide the trail for the shot itself, so it isn't in the picture.
        overlays.forEach { $0.alphaValue = 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-D", String(index + 1), url.path]
        try? p.run()
        p.waitUntilExit()
        overlays.forEach { $0.alphaValue = 1 }
        guard FileManager.default.fileExists(atPath: url.path) else {
            DFLog.log("circle", "screenshot failed (Screen Recording allowed?)")
            return
        }
        captured.append(url)
        NSSound(named: "Tink")?.play()
        trail.pulse = g
        DFLog.log("circle", "captured \(url.lastPathComponent)")
    }

    private func showTrail() {
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = NSHostingView(rootView: TrailView(model: trail, screenFrame: screen.frame))
            w.orderFrontRegardless()
            overlays.append(w)
        }
    }
}

/// The last second of pointer positions, for the blue trail.
final class TrailModel: ObservableObject {
    @Published var points: [(CGPoint, TimeInterval)] = []
    @Published var pulse: CircleGestureDetector.Gesture?
    func add(_ p: CGPoint, at t: TimeInterval) {
        points.append((p, t))
        points.removeAll { t - $0.1 > 0.9 }
    }
}

private struct TrailView: View {
    @ObservedObject var model: TrailModel
    let screenFrame: CGRect
    @State private var pulseScale: CGFloat = 1

    var body: some View {
        ZStack {
            Path { path in
                let pts = model.points.map(local)
                guard let first = pts.first else { return }
                path.move(to: first)
                pts.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(Color(red: 0.25, green: 0.55, blue: 1).opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if let g = model.pulse {
                Circle()
                    .stroke(Color(red: 0.25, green: 0.55, blue: 1), lineWidth: 3)
                    .frame(width: g.radius * 2, height: g.radius * 2)
                    .scaleEffect(pulseScale)
                    .opacity(2 - Double(pulseScale))
                    .position(local(g.center))
                    .onAppear { pulseScale = 1; withAnimation(.easeOut(duration: 0.6)) { pulseScale = 1.6 } }
                    .id(g.center.x + g.center.y)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
    }

    /// Screen point (bottom-left origin) → this view (top-left origin).
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y) }
    private func local(_ e: (CGPoint, TimeInterval)) -> CGPoint { local(e.0) }
}
