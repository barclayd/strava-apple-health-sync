import Foundation

/// Retains one summary page, one in-flight workout and scalar progress, never an archive/outcome list.
/// The existing protected journal supplies durable identity and undo across launches.
@MainActor public final class StreamingHistoryImport {
    public static let pageSize = 50
    public let query: ActivityQuery?
    private let selectedIDs: [Int64]?
    private var buffer: [StravaActivity] = []
    private var cursor = 0
    private var page = 1
    private var recentPages: [Set<Int64>] = []
    public private(set) var imported = 0
    public private(set) var skipped = 0
    public private(set) var running = false
    public private(set) var paused = false
    public private(set) var finished = false
    public private(set) var currentDate: Date?
    public private(set) var lastResult: (id: Int64, outcome: HistoryImportOutcome)?
    public var retainedSummaryCount: Int { buffer.count }
    public var processed: Int { imported + skipped }
    public var nextID: Int64? {
        if let selectedIDs { return selectedIDs.indices.contains(cursor) ? selectedIDs[cursor] : nil }
        return buffer.indices.contains(cursor) ? buffer[cursor].id : nil
    }

    public init(query: ActivityQuery) { self.query = query; selectedIDs = nil }
    public init(ids: Set<Int64>) { query = nil; selectedIDs = ids.sorted() }
    public func pause() { paused = true }
    public func skip() {
        guard !running, let id = nextID else { return }
        record(.skipped, id: id)
    }

    public func run(
        loadPage: @MainActor (ActivityQuery, Int, Int) async throws -> [StravaActivity],
        isImported: @MainActor (Int64) -> Bool,
        fetch: @MainActor (Int64) async throws -> Activity,
        save: @MainActor (Activity) async throws -> HistoryImportOutcome,
        changed: @MainActor () -> Void = {}
    ) async throws {
        guard !running, !finished else { return }
        running = true; paused = false
        defer { running = false; changed() }
        while !paused && !finished {
            try Task.checkCancellation()
            if selectedIDs == nil && cursor >= buffer.count {
                buffer = []; cursor = 0; currentDate = nil; changed()
                guard page <= 10_000 else { throw ImportProblem("This import reached its page limit. Completed imports are kept.") }
                let values = try await loadPage(query!, page, Self.pageSize)
                guard values.count <= Self.pageSize else { throw ImportProblem("Strava returned an oversized page.") }
                if values.isEmpty { finished = true; break }
                let ids = Set(values.map(\.id))
                guard !recentPages.contains(ids) else { throw ImportProblem("Strava repeated an activity page. Import paused; try again later.") }
                recentPages.append(ids)
                if recentPages.count > 16 { recentPages.removeFirst() }
                var seen = Set<Int64>()
                buffer = values.filter { seen.insert($0.id).inserted }
                page += 1
                changed()
                if paused { break }
            }
            guard let id = nextID else { finished = true; break }
            if selectedIDs == nil {
                currentDate = buffer[cursor].startDate
                if buffer[cursor].sport == nil { record(.skipped, id: id); changed(); continue }
            }
            if isImported(id) { record(.alreadyImported, id: id); changed(); await Task.yield(); continue }
            let activity = try await fetch(id)
            guard activity.stravaID == id else { throw ImportProblem("Strava returned the wrong activity. Import paused.") }
            if paused { break }
            currentDate = activity.start; changed()
            var selected = activity
            selected.activeEnergy = activity.stravaCalories
            // Pause events and all measurements keep their original timestamps.
            record(try await save(selected), id: id)
            changed()
        }
    }

    private func record(_ outcome: HistoryImportOutcome, id: Int64) {
        if outcome == .imported { imported += 1 } else { skipped += 1 }
        lastResult = (id, outcome); cursor += 1
        if let selectedIDs, cursor == selectedIDs.count { finished = true }
    }
}
