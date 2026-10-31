import SwiftUI
import ActivityImportCore

struct HistorySyncView: View {
    @Bindable var strava: StravaConnection
    @Bindable var model: ImportModel
    var synthetic = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var queue: HistoryImportQueue?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanning = false
    @State private var running = false
    @State private var pauseRequested = false
    @State private var scannedCount = 0
    @State private var unsupportedCount = 0
    @State private var outcomes: [Int64: HistoryImportOutcome] = [:]
    @State private var currentName: String?
    @State private var error: String?
    @State private var reviewed = false
    @State private var confirm = false
    @State private var useCalories = false
    @State private var usePauses = true

    private var completedIDs: Set<String> { Set(model.records.filter(\.completed).map(\.activityID)) }
    private var active: Bool { scanning || running }
    private var finished: Bool { queue != nil && queue?.next == nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your history, on your device.").font(.title2.bold())
                    if synthetic { Label("Invented data · simulator Health only", systemImage: "testtube.2").foregroundStyle(.indigo) }
                    Text("Review all available runs and rides before importing. Each workout uses the same mapping as your trial ride, including available cycling data and elevation.")
                    if queue == nil && !scanning {
                        Button(synthetic ? "Load synthetic history" : "Load Strava history") { load() }.accessibilityIdentifier("loadHistory")
                    }
                    if scanning {
                        ProgressView("Found \(scannedCount) activities…")
                        Button("Cancel loading", role: .cancel) { scanTask?.cancel() }
                    }
                } footer: { Text("Loading history reads summaries only. Nothing is written to Health until you confirm the import.") }

                if let queue {
                    Section {
                        LabeledContent("Runs and rides", value: "\(queue.activities.count)")
                        LabeledContent("Other sports excluded", value: "\(unsupportedCount)")
                        LabeledContent("Already in import history", value: "\(queue.activities.filter { completedIDs.contains("strava-v1-\($0.id)") }.count)")
                        if let oldest = queue.activities.map(\.startDate).min(), let newest = queue.activities.map(\.startDate).max() {
                            Text("\(oldest.formatted(date: .abbreviated, time: .omitted)) – \(newest.formatted(date: .abbreviated, time: .omitted))")
                        }
                    } header: { Text("Review") }

                    Group {
                        Section {
                            Toggle("Use Strava calories as active energy", isOn: $useCalories)
                            Toggle("Treat detected breaks as pauses", isOn: $usePauses)
                        } footer: {
                            Text("The calorie choice applies to every imported activity. Strava has no active/resting split. Break timing is estimated; original timestamps stay intact and Fitness may still display gaps. Missing measurements remain absent.")
                        }
                    }.disabled(running || !outcomes.isEmpty)

                    if !running && !finished {
                        Section {
                            Toggle("I’ve reviewed this history and my existing Health workouts", isOn: $reviewed)
                            Button(outcomes.isEmpty ? "Import history into Health" : "Resume import") { confirm = true }
                                .disabled(!reviewed || model.journalError != nil || (!strava.connected && !synthetic) || (synthetic && !model.canImportExample) || model.records.contains { !$0.completed })
                                .accessibilityIdentifier("importHistory")
                        } footer: {
                            Text("Allow full workout read access. We skip completed imports and matching workouts that Health lets us see. Denied or limited read access can hide duplicates. Keep the app open while importing.")
                        }
                    }

                    if running || !outcomes.isEmpty || finished {
                        Section {
                            ProgressView(value: Double(outcomes.count), total: Double(max(1, queue.activities.count)))
                            Text("\(outcomes.count) of \(queue.activities.count) processed")
                            LabeledContent("Imported", value: "\(outcomes.values.filter { $0 == .imported }.count)")
                            LabeledContent("Already imported / matching", value: "\(outcomes.values.filter { $0 == .alreadyImported || $0 == .duplicate }.count)")
                            LabeledContent("Skipped by you", value: "\(outcomes.values.filter { $0 == .skipped }.count)")
                            if running {
                                if let currentName { Text(currentName).foregroundStyle(.secondary) }
                                Button(pauseRequested ? "Finishing current activity…" : "Pause import") {
                                    queue.pause(); pauseRequested = true
                                }.disabled(pauseRequested)
                            } else if finished { Label("History processed", systemImage: "checkmark.circle") }
                            else { Text("Paused. Completed imports are kept.") }
                        } header: { Text("Progress") }
                    }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(.red)
                            if !running, let next = queue.next, !model.records.contains(where: { !$0.completed }) {
                                Button("Skip “\(next.name)”") {
                                    queue.skipNext(); outcomes = queue.outcomes; self.error = nil
                                }
                            }
                        } header: { Text("Import paused") }
                    }
                    Section {
                        ForEach(queue.activities) { activity in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.name).font(.headline)
                                Text("\(activity.startDate.formatted(date: .abbreviated, time: .shortened)) · \((activity.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let outcome = outcomes[activity.id] { Text(label(outcome)).font(.caption).foregroundStyle(.secondary) }
                                else if completedIDs.contains("strava-v1-\(activity.id)") { Text("Already imported · will skip").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    } header: { Text("Activities") }
                } else if let error { Section { Text(error).foregroundStyle(.red) } }
                if let journalError = model.journalError { Section { Text(journalError).foregroundStyle(.red) } }
                if model.records.contains(where: { !$0.completed }) {
                    Section { Text("An interrupted import needs cleanup. Close this screen and use Undo in import history before continuing.") }
                }
                Section {
                    Text("To resume after closing or restarting, load history again. The protected import journal skips completed imports. Skipped items and your choices are kept only for this session. Undo remains available per workout on the main screen.")
                }
            }
            .navigationTitle("Sync history").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(active) } }
            .interactiveDismissDisabled(active)
            .confirmationDialog("Import the reviewed runs and rides into Apple Health?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Start import") { Task { await run() } }
            } message: { Text("Workouts are processed one at a time. Existing matches are skipped. You can pause after the current activity; Strava limits or errors also pause the import.") }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    scanTask?.cancel()
                    queue?.pause()
                    if running { pauseRequested = true }
                }
            }
        }
    }

    private func load() {
        guard !active else { return }
        scanning = true; error = nil; scannedCount = 0; model.historyRunning = true
        scanTask = Task { @MainActor in
            defer { scanning = false; model.historyRunning = false; scanTask = nil }
            do {
                let values: [StravaActivity]
                if synthetic { values = try syntheticActivities().map(\.0) }
                else {
                    values = try await strava.loadHistory { count in
                        await MainActor.run { scannedCount = count }
                    }
                }
                try Task.checkCancellation()
                unsupportedCount = values.filter { $0.sport == nil }.count
                queue = HistoryImportQueue(activities: values)
            } catch {
                self.error = Task.isCancelled ? "Loading stopped. Load history again when ready." : error.localizedDescription
            }
        }
    }

    private func run() async {
        guard let queue, !active else { return }
        running = true; pauseRequested = false; error = nil; model.historyRunning = true
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { running = false; currentName = nil; model.historyRunning = false; UIApplication.shared.isIdleTimerDisabled = previousIdle }
        do {
            try await queue.run(completedIDs: completedIDs, useCalories: useCalories, usePauses: usePauses,
                fetch: { id in
                    if synthetic {
                        guard let activity = try syntheticActivities().first(where: { $0.0.id == id })?.1 else {
                            throw ImportProblem("Synthetic activity not found.")
                        }
                        return activity
                    }
                    return try await strava.historyActivity(id: id)
                },
                save: { try await model.saveReviewed($0, synthetic: synthetic) },
                changed: { outcomes = queue.outcomes; currentName = queue.next?.name })
        } catch { self.error = error.localizedDescription }
        outcomes = queue.outcomes
    }

    private func syntheticActivities() throws -> [(StravaActivity, Activity)] {
        try ["synthetic-ride", "synthetic-paused-ride"].map { name in
            guard let detail = Bundle.main.url(forResource: name, withExtension: "json"),
                  let streams = Bundle.main.url(forResource: name + "-streams", withExtension: "json") else {
                throw ImportProblem("Synthetic preview is unavailable.")
            }
            let source = try StravaJSON.decode(StravaActivity.self, from: Data(contentsOf: detail))
            return (source, try source.activity(streams: StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streams))))
        }
    }

    private func label(_ outcome: HistoryImportOutcome) -> String {
        switch outcome {
        case .imported: "Imported"
        case .alreadyImported: "Already in import history · skipped"
        case .duplicate: "Matching Health workout · skipped"
        case .skipped: "Skipped by you"
        }
    }
}
