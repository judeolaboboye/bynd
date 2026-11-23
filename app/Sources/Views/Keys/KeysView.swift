import SwiftUI

/// Every shortcut in one list. Settings → Shortcuts and the Keys section both read it.
enum ByndKeys {
    struct Entry: Identifiable { let id = UUID(); let keys: [String]; let what: String }
    struct Group: Identifiable { let id = UUID(); let title: String; let entries: [Entry] }

    static let groups: [Group] = [
        Group(title: "Dictation (your voice, typed where the cursor is)", entries: [
            Entry(keys: ["Tap right ⌥"], what: "Start talking hands-free; tap right ⌥ again to stop and type it"),
            Entry(keys: ["Hold right ⌥"], what: "A quick one: talk while holding, let go to type it"),
            Entry(keys: ["Hold right ⌥", "T"], what: "This dictation becomes a task instead"),
            Entry(keys: ["Right ⌥", "V"], what: "Paste your last dictation again"),
            Entry(keys: ["Esc"], what: "Cancel while listening"),
        ]),
        Group(title: "Journal", entries: [
            Entry(keys: ["Double-tap right ⌥"], what: "Journal recording: talk, tap right ⌥ to finish. Saved in Journal, not typed"),
        ]),
        Group(title: "Draw (talk and circle what you mean)", entries: [
            Entry(keys: ["Hold left ⌥"], what: "Talk while holding; circle things on screen with the pointer to screenshot them. Let go: text and screenshots are pasted together. Every drawing is kept in Draw"),
        ]),
        Group(title: "Guide (ask how to do anything on your Mac)", entries: [
            Entry(keys: ["Right ⌥", "G"], what: "Ask Guide by voice from any app; press again to send. It answers out loud and can point at things"),
        ]),
        Group(title: "Tasks (record your screen and face while you work)", entries: [
            Entry(keys: ["Tasks section"], what: "Type what you\u{2019}re doing and press Start task, or switch events on in the calendar panel: Bynd asks \u{201C}Are you working?\u{201D} when they start"),
            Entry(keys: ["fn", "⌘"], what: "Stop a task recording (or Stop task in the Tasks section)"),
        ]),
        Group(title: "Meetings, captures and the app", entries: [
            Entry(keys: ["Right ⌥", "M"], what: "Start or stop meeting notes"),
            Entry(keys: ["fn", "Space"], what: "Screenshot for your agent"),
            Entry(keys: ["fn", "⌘"], what: "Start or stop a screen recording (screen, face and voice)"),
            Entry(keys: ["Right ⌥", "W"], what: "Open or hide the Bynd window"),
            Entry(keys: ["⌘", "N"], what: "Record a meeting"),
            Entry(keys: ["⌘", "1–8"], what: "Notes, Tasks, Flow, Journal, Captures, Draw, Guide, Keys"),
            Entry(keys: ["⌃", "⌘", "S"], what: "Hide or show the sidebar"),
            Entry(keys: ["⌘", ","], what: "Settings"),
        ]),
    ]
}

/// The Keys section: every shortcut on one page.
struct KeysView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NotionHeader(icon: .symbol("command"), title: "Keys",
                             description: "Every shortcut in Bynd. Your voice alone: tap or hold right \u{2325}. Your voice with drawing: hold left \u{2325} and circle things.") {
                    EmptyView()
                } below: { EmptyView() }
                ForEach(ByndKeys.groups) { group in
                    Text(group.title).font(DF.font(13, .semibold)).foregroundStyle(DF.muted)
                        .padding(.top, 26).padding(.bottom, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, e in
                            ShortcutRow(keys: e.keys, what: e.what, last: i == group.entries.count - 1)
                        }
                    }
                    .dfCard()
                }
            }
            .pageColumn()
            .padding(.top, 36).padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DF.paper)
    }
}
