import SwiftUI
import ActivityImportCore

@MainActor @Observable final class ActivityLibrary {
    static let previewSize = 5
    var activities: [StravaActivity] = []
    var selection = ActivitySelection()
    var month = Date()
    var loaded = false
    var loading = false
    var running = false
    var pauseRequested = false
    var browsePage = 1
    var canBrowseOlder = false
    var browseError: String?
    var importError: String?
    var importedCount = 0
    var skippedCount = 0
    var currentMonth: Date?
    var finished = false
    var previewConnected = false
    var matchedVisibleIDs: Set<Int64> = []
    private(set) var importer: StreamingHistoryImport?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var browseQuery = ActivityQuery(before: Date())

    static var preview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains("--preview-connected")
        #else
        false
        #endif
    }
    static var now: Date { preview ? Date(timeIntervalSince1970: 1_530_316_800) : Date() }
    var active: Bool { loading || running }
    var hasPending: Bool { importer != nil && !finished }
    var canSkip: Bool { importer?.nextID != nil }

    init() {
        month = Self.now
        selection = ActivitySelection(now: Self.now)
    }

    func selectionChanged() {
        guard !running else { return }
        importer = nil; importedCount = 0; skippedCount = 0; finished = false
        importError = nil; currentMonth = nil
    }

    func clear() {
        generation += 1; loadTask?.cancel(); loadTask = nil
        activities = []; loaded = false; loading = false; selection = ActivitySelection(now: Self.now)
        browseError = nil; matchedVisibleIDs = []
        selectionChanged()
    }

    func load(strava: StravaConnection, model: ImportModel, page: Int = 1, reset: Bool = true) {
        guard !running, !model.busy else { return }
        generation += 1
        let request = generation
        loadTask?.cancel()
        if reset {
            switch selection.scope {
            case .all: browseQuery = ActivityQuery(before: Self.now)
            case .individual: browseQuery = .month(containing: month)
            case .dates: browseQuery = .days(from: selection.start, through: selection.end)
            }
        }
        let query = browseQuery
        loading = true; browseError = nil; activities = []; matchedVisibleIDs = []
        model.message = nil; strava.message = nil; model.historyRunning = true
        loadTask = Task { @MainActor in
            defer {
                if generation == request { loading = false; model.historyRunning = false; loadTask = nil }
            }
            do {
                let values = try await self.page(query: query, number: page, size: Self.previewSize, strava: strava)
                try Task.checkCancellation()
                guard generation == request else { return }
                activities = values.filter { $0.sport != nil }.sorted { $0.startDate > $1.startDate }
                browsePage = page; canBrowseOlder = !values.isEmpty; loaded = true
                if selection.scope == .all, let latest = activities.first { month = latest.startDate }
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                browseError = error.localizedDescription
            }
        }
    }

    func pause() {
        if loading {
            loadTask?.cancel(); loading = false
            browseError = "Loading paused. Retry when you’re ready."
        }
        importer?.pause()
        if running { pauseRequested = true }
    }

    func run(strava: StravaConnection, model: ImportModel) async {
        guard !active, !model.busy, model.journalError == nil, !model.records.contains(where: { !$0.completed }) else { return }
        if importer == nil {
            switch selection.scope {
            case .all: importer = StreamingHistoryImport(query: ActivityQuery(before: Self.now))
            case .dates: importer = StreamingHistoryImport(query: .days(from: selection.start, through: selection.end))
            case .individual:
                guard !selection.ids.isEmpty else { return }
                importer = StreamingHistoryImport(ids: selection.ids)
            }
        }
        guard let importer, !finished else { return }
        running = true; pauseRequested = false; importError = nil
        model.message = nil; strava.message = nil; model.historyRunning = true
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false; model.historyRunning = false
            UIApplication.shared.isIdleTimerDisabled = previousIdle
        }
        do {
            try await importer.run(
                loadPage: { query, page, size in try await self.page(query: query, number: page, size: size, strava: strava) },
                isImported: { id in model.hasImported(stravaID: id) },
                fetch: { id in
                    if Self.preview { return try Self.exampleActivity(id: id) }
                    return try await strava.historyActivity(id: id)
                },
                save: { try await model.saveReviewed($0, synthetic: Self.preview) },
                changed: { self.updateProgress() })
        } catch { importError = error.localizedDescription }
        updateProgress()
    }

    func skip() {
        guard !running else { return }
        importer?.skip(); updateProgress(); importError = nil
    }

    private func updateProgress() {
        guard let importer else { return }
        importedCount = importer.imported; skippedCount = importer.skipped
        finished = importer.finished; currentMonth = importer.currentDate
        if let result = importer.lastResult, result.outcome == .duplicate,
           activities.contains(where: { $0.id == result.id }) { matchedVisibleIDs.insert(result.id) }
    }

    private func page(query: ActivityQuery, number: Int, size: Int, strava: StravaConnection) async throws -> [StravaActivity] {
        if !Self.preview { return try await strava.activityPage(query: query, page: number, size: size) }
        // Only 18 invented summaries in this simulator fixture, filtered before paging like the API.
        let values = try (0..<18).map { try Self.exampleSource(index: $0) }.filter { query.contains($0.startDate) }
        return Array(values.dropFirst((number - 1) * size).prefix(size))
    }

    private static func exampleSource(index: Int) throws -> StravaActivity {
        let names = ["Sunday by the river", "The long way home", "Coffee stop loop", "Before the city wakes", "A little further out", "Into the hills"]
        let dates = ["2018-06-24T08:00:00Z", "2018-06-21T17:30:00Z", "2018-06-17T09:00:00Z", "2018-06-12T06:15:00Z", "2018-05-27T08:00:00Z", "2018-05-12T09:30:00Z"]
        let original = index % 6
        let name = original == 2 ? "synthetic-paused-ride" : "synthetic-ride"
        guard let detail = Bundle.main.url(forResource: name, withExtension: "json") else { throw ImportProblem("Example unavailable.") }
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: detail)) as! [String: Any]
        let base = ISO8601DateFormatter().date(from: dates[original])!
        let date = Calendar(identifier: .gregorian).date(byAdding: .month, value: -(index / 6) * 2, to: base)!
        json["id"] = 9_100_000_001 + index; json["name"] = names[original]
        json["start_date"] = date.ISO8601Format()
        return try StravaJSON.decode(StravaActivity.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func exampleActivity(id: Int64) throws -> Activity {
        let index = Int(id - 9_100_000_001)
        guard (0..<18).contains(index) else { throw ImportProblem("Example unavailable.") }
        let name = index % 6 == 2 ? "synthetic-paused-ride" : "synthetic-ride"
        guard let streams = Bundle.main.url(forResource: name + "-streams", withExtension: "json") else { throw ImportProblem("Example unavailable.") }
        return try exampleSource(index: index).activity(streams: StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streams)))
    }
}
