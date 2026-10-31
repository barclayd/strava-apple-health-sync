import Foundation

public enum HistoryImportOutcome: String, Sendable {
    case imported, alreadyImported, duplicate, skipped
}

/// The queue contains summaries in memory. ImportJournal remains the durable source of truth.
/// After relaunch, reload history and supply the completed journal IDs to skip earlier imports.
@MainActor public final class HistoryImportQueue {
    public let activities: [StravaActivity]
    public private(set) var outcomes: [Int64: HistoryImportOutcome] = [:]
    public private(set) var running = false
    public private(set) var pauseRequested = false
    private var cursor = 0
    public var next: StravaActivity? { activities.indices.contains(cursor) ? activities[cursor] : nil }

    public init(activities: [StravaActivity]) {
        var seen = Set<Int64>()
        self.activities = activities.filter { $0.sport != nil && seen.insert($0.id).inserted }
    }

    public func pause() { pauseRequested = true }
    public func skipNext() {
        guard !running, let next else { return }
        outcomes[next.id] = .skipped
        cursor += 1
    }

    public func run(completedIDs: Set<String>, useCalories: Bool, usePauses: Bool,
                    fetch: @MainActor (Int64) async throws -> Activity,
                    save: @MainActor (Activity) async throws -> HistoryImportOutcome,
                    changed: @MainActor () -> Void = {}) async throws {
        guard !running else { return }
        running = true; pauseRequested = false
        defer { running = false; changed() }
        while let source = next, !pauseRequested {
            changed()
            if completedIDs.contains("strava-v1-\(source.id)") {
                outcomes[source.id] = .alreadyImported
                cursor += 1
                await Task.yield()
                continue
            }
            var activity = try await fetch(source.id)
            guard activity.stravaID == source.id else { throw ImportProblem("Strava returned the wrong activity. Sync is paused.") }
            if pauseRequested { break }
            activity.activeEnergy = useCalories ? activity.stravaCalories : nil
            if !usePauses { activity.pauses = [] }
            // A pause request waits for this transaction to finish or roll back.
            outcomes[source.id] = try await save(activity)
            cursor += 1
        }
    }
}
