import Foundation
import Observation
import ActivityImportCore

@MainActor @Observable final class ImportModel {
    var activities: [Activity] = []
    var records: [ImportRecord] = []
    var busy = false
    var message: String?
    var example = false
    var stravaSource: StravaActivity?
    var historyRunning = false
    var journalError: String?
    private var journal: ImportJournal?
    private let health = HealthWriter()

    init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true).appendingPathComponent("ImportJournal")
            journal = try ImportJournal(directory: directory)
            records = journal!.records
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

    func load(_ urls: [URL]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            // Parse off the main thread. Security-scoped access is released even when parsing fails.
            let parsed = try await Task.detached(priority: .userInitiated) {
                guard urls.count <= 20 else { throw ImportProblem("Choose up to 20 TCX files at a time.") }
                var result: [Activity] = []
                var totalBytes = 0
                for url in urls {
                    guard url.pathExtension.lowercased() == "tcx" else {
                        throw ImportProblem("Choose individual TCX files. FIT, GPX and ZIP archives are not supported in this POC.")
                    }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: TCXReader.maximumBytes + 1) ?? Data()
                    totalBytes += data.count
                    guard totalBytes <= TCXReader.maximumBytes else { throw ImportProblem("Choose files totalling no more than 20 MB.") }
                    result += try TCXReader.read(data)
                    guard result.count <= 100 else { throw ImportProblem("Choose up to 100 activities at a time.") }
                    guard result.reduce(0, { $0 + $1.points.count }) <= 100_000 else { throw ImportProblem("Choose files totalling no more than 100,000 track points.") }
                }
                var seen = Set<String>()
                return result.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
            }.value
            activities = parsed
            example = false
            stravaSource = nil
        } catch { message = error.localizedDescription }
    }

    func loadExample() async {
        guard !busy else { return }
        guard let url = Bundle.main.url(forResource: "historic-run", withExtension: "tcx") else { return }
        await load([url])
        example = true
    }

    func loadCyclingExample(withBreak: Bool = false) {
        guard !busy else { return }
        do {
            let name = withBreak ? "synthetic-paused-ride" : "synthetic-ride"
            guard let detailURL = Bundle.main.url(forResource: name, withExtension: "json"),
                  let streamsURL = Bundle.main.url(forResource: name + "-streams", withExtension: "json") else { return }
            let source = try StravaJSON.decode(StravaActivity.self, from: Data(contentsOf: detailURL))
            let streams = try StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streamsURL))
            activities = [try source.activity(streams: streams)]
            stravaSource = source; example = true
        } catch { message = error.localizedDescription }
    }

    func importActivity(_ activity: Activity) async {
        do {
            switch try await saveReviewed(activity, synthetic: example) {
            case .imported: message = "Imported into Apple Health. You can undo this import from the history below."
            case .alreadyImported: message = "This activity is already in your import history. Undo it before importing again."
            case .duplicate: message = "A matching or overlapping workout is already visible in Apple Health. Nothing was imported."
            case .skipped: break
            }
        } catch { message = error.localizedDescription }
    }

    func saveReviewed(_ activity: Activity, synthetic: Bool = false) async throws -> HistoryImportOutcome {
        guard !busy else { throw ImportProblem("Another import is still running.") }
        guard let journal else { throw ImportProblem(journalError ?? "Import history is unavailable.") }
        guard !synthetic || canImportExample else { throw ImportProblem("Synthetic imports only run in a simulator.") }
        busy = true
        defer { busy = false; records = journal.records }
        do {
            guard !journal.records.contains(where: { !$0.completed }) else {
                throw ImportProblem("An earlier import was interrupted. Close history sync and use Undo in import history to clean it up first.")
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
        defer { busy = false; records = journal.records }
        do {
            try await health.undo(record)
            try journal.remove(record.id)
            message = "Removed this import and its associated samples from Apple Health. Other apps’ data was left untouched."
        } catch { message = "Undo could not finish. Keep this app installed and retry after checking Health permissions and unlocking your device." }
    }
}
