import Foundation
import SwiftData
@testable import Bynd

/// A local date built on Bynd's calendar (weeks start Monday).
func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    Calendar.bynd.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// A fresh in-memory store for one test.
@MainActor
func makeContext() throws -> (ModelContainer, ModelContext) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: MeetingNote.self, MeetingFolder.self, DictationEntry.self, configurations: config)
    return (container, container.mainContext)
}
