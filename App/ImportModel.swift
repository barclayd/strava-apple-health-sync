import Foundation
import Observation
import ActivityImportCore

@MainActor @Observable final class ImportModel {
    var records: [ImportRecord] = []
    var busy = false
    var message: String?
    var historyRunning = false
    var journalError: String?
    private var importedIDs: Set<String> = []
    private var journal: ImportJournal?
    private let health = HealthWriter()

    init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true).appendingPathComponent("ImportJournal")
            journal = try ImportJournal(directory: directory)
            records = journal!.records
            importedIDs = Set(records.filter(\.completed).map(\.activityID))
        } catch {
            journalError = "Import history could not be opened. Imports are disabled to protect against duplicates. Restart after unlocking your device."
        }
    }

    var canImportExample: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func hasImported(stravaID: Int64) -> Bool { importedIDs.contains("strava-v1-\(stravaID)") }

    func saveReviewed(_ activity: Activity, synthetic: Bool = false) async throws -> HistoryImportOutcome {
        guard !busy else { throw ImportProblem("Another import is still running.") }
        guard let journal else { throw ImportProblem(journalError ?? "Import history is unavailable.") }
        guard !synthetic || canImportExample else { throw ImportProblem("Synthetic imports only run in a simulator.") }
        busy = true
        defer { busy = false; records = journal.records; importedIDs = Set(records.filter(\.completed).map(\.activityID)) }
        do {
            guard !journal.records.contains(where: { !$0.completed }) else {
                throw ImportProblem("An earlier import was interrupted. Open Import history from the menu and undo it first.")
            }
            if journal.records.contains(where: { $0.activityID == activity.id && $0.completed }) { return .alreadyImported }
            await AppDiagnostics.shared.record(.healthPermissionRequested)
            try await health.authorise(for: activity)
            await AppDiagnostics.shared.record(.healthPermissionGranted)
            if try await health.hasDuplicate(activity) {
                await AppDiagnostics.shared.record(.duplicateBlocked)
                return .duplicate
            }
            let record = ImportRecord(activity: activity)
            try journal.append(record)
            do {
                await AppDiagnostics.shared.record(.healthWriteStarted)
                try await health.save(activity, record: record)
                try journal.complete(record.id)
                await AppDiagnostics.shared.record(.healthWriteCompleted)
                return .imported
            } catch {
                let original = error
                do {
                    try await health.undo(record)
                    try journal.remove(record.id)
                    await AppDiagnostics.shared.record(.rollbackCompleted)
                } catch {
                    await AppDiagnostics.shared.record(.rollbackFailed)
                    throw ImportProblem("Import was interrupted and cleanup could not finish. Keep this app installed and use Undo in import history to retry cleanup.")
                }
                throw ImportProblem("Import failed and its saved data was removed: \(original.localizedDescription)")
            }
        } catch { await AppDiagnostics.shared.record(.importFailed); throw error }
    }

    func undo(_ record: ImportRecord) async {
        guard !busy, let journal else { return }
        busy = true
        defer { busy = false; records = journal.records; importedIDs = Set(records.filter(\.completed).map(\.activityID)) }
        do {
            try await health.undo(record)
            try journal.remove(record.id)
            message = "Removed this import and its associated samples from Apple Health. Other apps’ data was left untouched."
        } catch { message = "Undo could not finish. Keep this app installed and retry after checking Health permissions and unlocking your device." }
    }
}
