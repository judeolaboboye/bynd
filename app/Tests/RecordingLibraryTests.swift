import XCTest
@testable import Bynd

final class RecordingLibraryTests: XCTestCase {
    func testPartsFolderSitsNextToTheRecording() {
        let raw = URL(fileURLWithPath: "/tmp/x/capture-2026-11-23-10.00.00.mp4")
        XCTAssertEqual(RecordingLibrary.partsFolder(for: raw).lastPathComponent, "capture-2026-11-23-10.00.00 parts")
    }

    func testSavePartsCopiesSeparateTracks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        let take = root.appendingPathComponent("take"); try fm.createDirectory(at: take, withIntermediateDirectories: true)
        try Data("s".utf8).write(to: take.appendingPathComponent("screen.mov"))
        try Data("m".utf8).write(to: take.appendingPathComponent("mic.mov"))
        let cam = root.appendingPathComponent("camera.mov"); try Data("c".utf8).write(to: cam)
        let raw = root.appendingPathComponent("capture-2026-11-23-10.00.00.mp4"); try Data("r".utf8).write(to: raw)
        RecordingLibrary.saveParts(takeDirectory: take, camera: cam, raw: raw)
        let names = RecordingLibrary.parts(for: raw).map(\.lastPathComponent)
        XCTAssertEqual(Set(names), ["screen only.mov", "camera only.mov", "voice (mic).mov"])
        try? fm.removeItem(at: root)
    }

    func testGBFormatting() {
        XCTAssertEqual(RecordingLibrary.gb(20 * 1_073_741_824), "20.0 GB")
    }
}
