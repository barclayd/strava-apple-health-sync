import SwiftUI
import ActivityImportCore

@MainActor @Observable final class ActivityLibrary {
    var activities: [StravaActivity] = []
    var selection = ActivitySelection()
    var loaded = false
    var loading = false
    var running = false
    var pauseRequested = false
    var scannedCount = 0
    var error: String?
    var outcomes: [Int64: HistoryImportOutcome] = [:]
    var currentName: String?
    var previewConnected = false
    private(set) var queue: HistoryImportQueue?
    private var loadTask: Task<Void, Never>?

    static var preview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains("--preview-connected")
        #else
        false
        #endif
    }

    var selected: [StravaActivity] { selection.activities(in: activities) }
    var visible: [StravaActivity] { selection.scope == .dates ? selected : activities }
    var active: Bool { loading || running }
    var finished: Bool { queue != nil && queue?.next == nil }
    var hasPending: Bool { queue?.next != nil }

    func pending(records: [ImportRecord]) -> [StravaActivity] {
        let imported = Set(records.filter(\.completed).map(\.activityID))
        return selected.filter {
            !imported.contains("strava-v1-\($0.id)") && outcomes[$0.id] != .duplicate
        }
    }

    func selectionChanged() {
        guard !running else { return }
        queue = nil; outcomes = [:]; error = nil
    }

    func clear() {
        loadTask?.cancel()
        activities = []; loaded = false; selection = ActivitySelection()
        selectionChanged()
    }

    func load(strava: StravaConnection, model: ImportModel) {
        guard !active, !model.busy else { return }
        loading = true; error = nil; scannedCount = 0; model.historyRunning = true
        loadTask = Task { @MainActor in
            defer { loading = false; model.historyRunning = false; loadTask = nil }
            do {
                let values: [StravaActivity]
                if Self.preview { values = try Self.examples().map(\.0) }
                else {
                    values = try await strava.loadHistory { count in
                        await MainActor.run { self.scannedCount = count }
                    }
                }
                try Task.checkCancellation()
                activities = values.filter { $0.sport != nil }.sorted { $0.startDate > $1.startDate }
                loaded = true
                if Self.preview, let first = activities.last?.startDate, let last = activities.first?.startDate {
                    selection.start = first; selection.end = last
                }
                selectionChanged()
            } catch {
                self.error = Task.isCancelled ? "Loading paused. Tap retry when you’re ready." : error.localizedDescription
            }
        }
    }

    func pause() {
        loadTask?.cancel()
        queue?.pause()
        if running { pauseRequested = true }
    }

    func run(strava: StravaConnection, model: ImportModel) async {
        guard !active, !model.busy, model.journalError == nil, !model.records.contains(where: { !$0.completed }) else { return }
        if queue == nil || finished {
            let values = pending(records: model.records)
            guard !values.isEmpty else { return }
            queue = HistoryImportQueue(activities: values)
            outcomes = [:]
        }
        guard let queue else { return }
        running = true; pauseRequested = false; error = nil; model.historyRunning = true
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            running = false; currentName = nil; model.historyRunning = false
            UIApplication.shared.isIdleTimerDisabled = previousIdle
        }
        do {
            try await queue.run(completedIDs: Set(model.records.filter(\.completed).map(\.activityID)),
                useCalories: true, usePauses: true,
                fetch: { id in
                    if Self.preview {
                        guard let value = try Self.examples().first(where: { $0.0.id == id })?.1 else {
                            throw ImportProblem("The example activity is unavailable.")
                        }
                        return value
                    }
                    return try await strava.historyActivity(id: id)
                },
                save: { try await model.saveReviewed($0, synthetic: Self.preview) },
                changed: { self.outcomes = queue.outcomes; self.currentName = queue.next?.name })
        } catch { self.error = error.localizedDescription }
        outcomes = queue.outcomes
    }

    func skip() {
        guard !running else { return }
        queue?.skipNext(); outcomes = queue?.outcomes ?? [:]; error = nil
    }

    // Explicit simulator launch arguments only. No demo entry or synthetic writes on a phone.
    private static func examples() throws -> [(StravaActivity, Activity)] {
        let rides = [
            ("Sunday by the river", "2018-06-24T08:00:00Z"),
            ("The long way home", "2018-06-21T17:30:00Z"),
            ("Coffee stop loop", "2018-06-17T09:00:00Z"),
            ("Before the city wakes", "2018-06-12T06:15:00Z"),
            ("A little further out", "2018-05-27T08:00:00Z"),
            ("Into the hills", "2018-05-12T09:30:00Z")
        ]
        return try rides.enumerated().map { index, ride in
            let name = index == 2 ? "synthetic-paused-ride" : "synthetic-ride"
            guard let detail = Bundle.main.url(forResource: name, withExtension: "json"),
                  let streams = Bundle.main.url(forResource: name + "-streams", withExtension: "json") else {
                throw ImportProblem("The example activities are unavailable.")
            }
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: detail)) as! [String: Any]
            json["id"] = 9_100_000_001 + index; json["name"] = ride.0; json["start_date"] = ride.1
            let source = try StravaJSON.decode(StravaActivity.self, from: JSONSerialization.data(withJSONObject: json))
            let points = try StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streams))
            return (source, try source.activity(streams: points))
        }
    }
}
