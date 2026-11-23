import AppKit
import SwiftUI

/// Screenshots: every picture taken by circling things while holding left ⌥.
/// Files live in ~/Pictures/Bynd/Draw. Delete moves them to the Trash.
struct CircleScreenshotsView: View {
    @State private var files: [URL] = []
    @State private var selected = Set<URL>()
    @State private var notes: [String: String] = DrawNotes.all()
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NotionHeader(icon: .symbol("pencil.and.scribble"), title: "Draw",
                             description: "Hold left \u{2325} and circle anything on screen. Each circle is a cropped screenshot of just that area, kept here and put on your clipboard. Write what each one is about below it.") {
                    EmptyView()
                } below: { EmptyView() }
                HStack {
                    Text(files.isEmpty ? "" : "\(files.count) screenshot\(files.count == 1 ? "" : "s")")
                        .font(DF.font(13)).foregroundStyle(DF.muted)
                    Spacer()
                    if !selected.isEmpty {
                        Button("Delete \(selected.count) selected") { trash(Array(selected)) }
                    }
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: CircleCapture.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(CircleCapture.folder)
                    }
                }
                .padding(.top, 20).padding(.bottom, 12)
                Hairline()
                if files.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing drawn yet").font(DF.font(16, .semibold))
                        Text("Hold left \u{2325} and draw a circle around something with the pointer.")
                            .font(DF.font(15)).foregroundStyle(DF.muted)
                    }
                    .padding(.top, 28)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(files, id: \.self) { url in tile(url) }
                    }
                    .padding(.top, 16)
                }
            }
            .pageColumn()
            .padding(.top, 36).padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DF.paper)
        .onAppear(perform: load)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in load() }
    }

    private func tile(_ url: URL) -> some View {
        let isSel = selected.contains(url)
        return VStack(alignment: .leading, spacing: 6) {
            Thumb(url: url)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSel ? DF.ink : DF.line, lineWidth: isSel ? 2 : 1))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                .onTapGesture { if isSel { selected.remove(url) } else { selected.insert(url) } }
            Text(url.deletingPathExtension().lastPathComponent).font(DF.font(12)).foregroundStyle(DF.muted).lineLimit(1)
            TextField("Describe this screenshot\u{2026}", text: Binding(
                get: { notes[url.lastPathComponent] ?? "" },
                set: { v in notes[url.lastPathComponent] = v; DrawNotes.set(v, for: url.lastPathComponent) }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder).font(DF.font(13)).lineLimit(1...4)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy") {
                if let img = NSImage(contentsOf: url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) }
            }
            Divider()
            Button("Delete", role: .destructive) { trash([url]) }
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }

    private func load() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: CircleCapture.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let pngs = items.filter { $0.pathExtension.lowercased() == "png" }
        let sorted = pngs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        if sorted != files { files = sorted; selected = selected.filter(sorted.contains) }
    }

    private func trash(_ urls: [URL]) {
        for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        selected.subtract(urls)
        load()
    }
}

private struct Thumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            DF.canvas
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .task(id: url) {
            let u = url
            image = await Task.detached { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}
