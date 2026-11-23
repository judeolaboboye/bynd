import SwiftUI
import SwiftData

/// Journal: double-tap right ⌥ recordings. Transcribed like Flow, but kept here instead of typed.
struct JournalView: View {
    @Query(filter: #Predicate<DictationEntry> { $0.destination == "journal" },
           sort: \DictationEntry.createdAt, order: .reverse) private var entries: [DictationEntry]
    @State private var query = ""

    private var filtered: [DictationEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? entries : entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                NotionHeader(icon: .symbol("book.closed"), title: "Journal",
                             description: "Double-tap right \u{2325}, talk as long as you like, tap right \u{2325} to finish. It\u{2019}s written down here, not typed anywhere.") {
                    EmptyView()
                } below: { EmptyView() }
                Hairline().padding(.top, 24)
                if !entries.isEmpty {
                    SearchField(text: $query, prompt: "Search your journal").frame(width: 260).padding(.top, 14)
                }
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No journal entries yet").font(DF.font(16, .semibold))
                        Text("Double-tap right \u{2325} to start one.").font(DF.font(15)).foregroundStyle(DF.muted)
                    }
                    .padding(.top, 28)
                } else if filtered.isEmpty {
                    Text("Nothing matches \u{201C}\(query)\u{201D}").font(DF.font(15)).foregroundStyle(DF.muted).padding(.top, 28)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(DictationView.days(filtered), id: \.day) { group in
                            DayHeader(day: group.day, entries: group.entries)
                            ForEach(group.entries) { e in EntryRow(entry: e) }
                        }
                    }
                }
            }
            .pageColumn()
            .padding(.top, 36).padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DF.paper)
    }
}
