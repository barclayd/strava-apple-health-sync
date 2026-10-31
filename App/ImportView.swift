import SwiftUI
import UniformTypeIdentifiers
import ActivityImportCore

struct ImportView: View {
    @Bindable var model: ImportModel
    @Bindable var strava: StravaConnection
    @State private var showFiles = false
    @State private var showPrivacy = false
    @State private var undoRecord: ImportRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "heart.text.clipboard")
                            .font(.system(size: 36, weight: .medium)).foregroundStyle(.indigo)
                            .accessibilityHidden(true)
                        Text("Bring old workouts\ninto Apple Health.")
                            .font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        Text("Connect with Strava, review a workout, then save it to Health. Start with yesterday’s activity.")
                            .font(.body).foregroundStyle(.secondary)
                        Label("Direct to your device. No activity uploads.", systemImage: "lock.shield")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.indigo)
                    }.padding(.vertical, 14)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                StravaTrialSection(strava: strava, model: model)

                Section {
                  DisclosureGroup("Import a file or explore an example") {
                    Button { showFiles = true } label: {
                        Label("Choose TCX files", systemImage: "doc.badge.plus").font(.headline).padding(.vertical, 8)
                    }.accessibilityIdentifier("chooseFiles")
                    Button { Task { await model.loadExample() } } label: {
                        Label("Preview a synthetic example", systemImage: "play.circle")
                    }.accessibilityIdentifier("loadExample")
                    Button { model.loadCyclingExample() } label: {
                        Label("Preview a synthetic ride", systemImage: "bicycle")
                    }.accessibilityIdentifier("loadCyclingExample")
                    Button { model.loadCyclingExample(withBreak: true) } label: {
                        Label("Preview a ride with a break", systemImage: "pause.circle")
                    }.accessibilityIdentifier("loadPausedExample")
                  }
                } header: { Text("Other options") } footer: {
                    Text("This trial imports one Strava run or ride. Full-history sync will follow after checking the result in Health.")
                }

                if let error = model.journalError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if !model.activities.isEmpty {
                    Section {
                        ForEach(model.activities) { activity in
                            NavigationLink {
                                ActivityView(activity: activity, model: model)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: activity.sport.symbol).font(.title2).foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(activity.sport.title).font(.headline)
                                        Text(activity.start.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(activity.distance / 1000, format: .number.precision(.fractionLength(2)))
                                        .monospacedDigit()
                                    Text("km").foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("activity-\(activity.id)")
                        }
                        Button("Clear preview", role: .destructive) { model.activities = []; model.example = false; model.stravaSource = nil }
                    } header: { Text(model.example ? "Synthetic example" : "Ready to review") } footer: {
                        if model.example {
                            Text(model.canImportExample ? "Invented data. Imports here use only this simulator’s Health store." : "Invented data for a read-only preview. Connect Strava or choose your own file to import.")
                        } else { Text("Previews are held in memory. Activity data is not saved to an app cache.") }
                    }
                }

                if !model.records.isEmpty {
                    Section {
                        ForEach(model.records.reversed()) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(record.sport.title, systemImage: record.sport.symbol).font(.headline)
                                    Spacer()
                                    Text(record.completed ? "Imported" : "Cleanup needed")
                                        .font(.caption.weight(.medium)).foregroundStyle(record.completed ? Color.secondary : Color.orange)
                                }
                                Text(record.start.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button(record.completed ? "Undo import" : "Undo interrupted import", role: .destructive) {
                                    undoRecord = record
                                }.accessibilityIdentifier("undoImport")
                            }.padding(.vertical, 4)
                        }
                    } header: { Text("Import history") } footer: {
                        Text("Undo removes this app’s workout and all associated samples for that import. Keep the app installed until you’ve checked the result.")
                    }
                }
                Section {
                    Button { showPrivacy = true } label: { Label("How your data stays private", systemImage: "hand.raised") }
                } footer: {
                    Text("Apple Health may sync with iCloud if you have enabled it. Files you choose may come from a cloud provider. Those services follow your own settings.")
                }
            }
            .navigationTitle("Health Import").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [UTType(importedAs: "com.garmin.tcx"), .xml],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.load(urls) }
                case .failure: model.message = "The files could not be opened. Try choosing them again."
                }
            }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
            .confirmationDialog("Remove this import from Apple Health?", isPresented: Binding(
                get: { undoRecord != nil }, set: { if !$0 { undoRecord = nil } }), titleVisibility: .visible) {
                    if let record = undoRecord {
                        Button("Remove imported data", role: .destructive) { Task { await model.undo(record) }; undoRecord = nil }
                    }
                } message: { Text("Only records created by this app for the selected import will be deleted.") }
        }
        .overlay { if model.busy || strava.busy { ProgressView(strava.busy ? "Connecting to Strava…" : "Working on device…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .disabled(model.busy || strava.busy)
        .alert("Health Import", isPresented: Binding(get: { model.message != nil || strava.message != nil }, set: { if !$0 { model.message = nil; strava.message = nil } })) {
            Button("OK") { model.message = nil; strava.message = nil }
        } message: { Text(model.message ?? strava.message ?? "") }
    }
}

struct ActivityView: View {
    let activity: Activity
    @Bindable var model: ImportModel
    @State private var reviewed = false
    @State private var confirm = false
    @State private var useCaloriesAsActive = false
    @State private var usePauses = true

    private var alreadyImported: Bool { model.records.contains { $0.activityID == activity.id } }

    var body: some View {
        List {
            Section {
                LabeledContent("Activity", value: activity.sport.title)
                LabeledContent("Started", value: activity.start.formatted(date: .abbreviated, time: .shortened))
                if let source = model.stravaSource, source.id == activity.stravaID {
                    LabeledContent("Strava activity", value: source.name)
                    LabeledContent("Strava moving time", value: duration(Double(source.movingTime)))
                    if let device = source.deviceName { LabeledContent("Recorded with", value: device) }
                    if !model.example { Link("View on Strava", destination: URL(string: "https://www.strava.com/activities/\(source.id)")!) }
                }
                LabeledContent(activity.stravaID == nil ? "Timer duration" : "Workout duration", value: duration(usePauses ? activity.workoutDuration : activity.duration))
                LabeledContent("Elapsed time", value: duration(activity.end.timeIntervalSince(activity.start)))
                LabeledContent("Distance", value: "\((activity.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                LabeledContent("Heart-rate samples", value: "\(activity.heartRatePoints.count)")
                LabeledContent("Route points", value: "\(activity.routePoints.count)")
                if activity.stravaID != nil {
                    LabeledContent("Strava calories", value: activity.stravaCalories.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kcal" } ?? "Not provided")
                    if let gain = activity.elevationGain { LabeledContent("Elevation gain", value: "\(gain.formatted(.number.precision(.fractionLength(0)))) m") }
                    if let indoor = activity.indoor { LabeledContent("Location", value: indoor ? "Indoor" : "Outdoor") }
                    if activity.sport == .cycling {
                        LabeledContent("Power samples", value: sampleCount(activity.powerPoints.count))
                        if !activity.powerPoints.isEmpty { LabeledContent("Power source", value: activity.powerIsEstimated ? "Strava estimate / unspecified" : "Power meter") }
                        LabeledContent("Cadence samples", value: sampleCount(activity.cadencePoints.count))
                        LabeledContent("Speed samples", value: sampleCount(activity.speedPoints.count))
                    }
                }
            } header: { Text(model.example ? "Synthetic activity" : "What will be imported") } footer: {
                Text(activity.stravaID == nil
                    ? "Original timestamps and timer duration are preserved. Calories, cadence and power are not imported in this POC."
                    : "Original timestamps are preserved. Detected breaks can be excluded from workout duration using Health pause/resume events. Strava moving time is shown separately. Available cycling streams retain their timestamps; missing measurements stay absent.")
            }
            if !activity.pauses.isEmpty {
                Section {
                    Toggle("Treat detected breaks as pauses", isOn: $usePauses)
                        .accessibilityIdentifier("useDetectedPauses")
                    LabeledContent("Detected breaks", value: "\(activity.pauses.count)")
                    LabeledContent("Time paused", value: duration(activity.pausedDuration))
                    DisclosureGroup("Review break times") {
                        ForEach(Array(activity.pauses.enumerated()), id: \.offset) { _, pause in
                            LabeledContent("\(pause.start.formatted(date: .omitted, time: .standard)) – \(pause.end.formatted(date: .omitted, time: .standard))", value: duration(pause.duration))
                        }
                    }
                } footer: {
                    Text("Break timing is estimated from Strava’s movement samples and stationary recording gaps. It may differ from Garmin’s original timer. Health receives pause/resume events; Fitness controls how its graphs display them. Turn this off to keep the full elapsed duration.")
                }
            }
            if activity.stravaCalories != nil {
                Section {
                    Toggle("Use Strava calories as active energy", isOn: $useCaloriesAsActive)
                        .accessibilityIdentifier("useStravaCalories")
                } footer: {
                    Text("Strava supplies one calorie value without an active/resting breakdown. Enable this if it represents activity calories from your recording. It will be saved as active energy and may affect your Move ring. Resting calories are not added or estimated.")
                }
            }
            if alreadyImported {
                Section {
                    Text("This workout is already imported. To try the richer import, go back to Import history and undo the earlier copy first, then review and save again.")
                }
            }
            Section {
                Label("Check your existing workouts", systemImage: "checkmark.shield")
                    .font(.headline)
                Text("We check workouts Health lets us read and block likely duplicates. Health does not tell apps when read access is denied, and limited access can hide older workouts.")
                Text("Allow full workout history in the Health permission sheet. Review this date in Health before proceeding; an empty result does not prove the workout is missing.")
                    .foregroundStyle(.secondary)
                Toggle("I’ve checked this date in Health", isOn: $reviewed)
                    .accessibilityIdentifier("reviewedHealth")
            }
            Section {
                Button { confirm = true } label: {
                    Label(alreadyImported ? "Already in import history" : "Import into Apple Health", systemImage: "heart.fill")
                        .font(.headline).padding(.vertical, 6)
                }
                .accessibilityIdentifier("importActivity")
                .disabled(!reviewed || alreadyImported || model.busy || model.journalError != nil || (model.example && !model.canImportExample) || (activity.stravaID != nil && model.stravaTrialComplete))
            } footer: {
                Text("Health will list Health Import as the source. You can undo the import from this app’s history.")
            }
        }
        .navigationTitle(activity.sport == .cycling ? "Review ride" : "Review workout").navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .confirmationDialog("Save this workout and its samples to Health?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Save to Health") {
                var selected = activity
                selected.activeEnergy = useCaloriesAsActive ? activity.stravaCalories : nil
                if !usePauses { selected.pauses = [] }
                Task { await model.importActivity(selected) }
            }
        } message: { Text("Nothing is uploaded by Health Import. Your Apple Health iCloud settings still apply.") }
    }

    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    private func sampleCount(_ count: Int) -> String { count == 0 ? "Not provided" : "\(count)" }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What this app does") {
                    Text("Connects directly to Strava to read your selected day’s activities and the workout you choose, including its recorded heart rate and route when available. Preview and duplicate checks run on your device. TCX file import is also available.")
                    Text("Writes the selected workout and available distance, heart rate, route, cycling power, cadence, speed and elevation gain to Apple Health with your permission. Strava calories are written as active energy only when you enable that choice.")
                    Text("Keeps a small import history on this device for duplicate protection and undo. That history is excluded from device backups. Original files are not copied into the app.")
                }
                Section("What we collect") {
                    Text("The developer receives no activities or Health data. There is no app backend, analytics, advertising or crash-reporting service. Network requests go directly to Strava for sign-in and activity reads. Strava may collect API usage information under its own policy.")
                    Text("Strava tokens are stored in this device’s Keychain, available only while unlocked and excluded from syncing and migration. Activity previews are held in memory, without a disk cache.")
                    Text("This development build keeps a short local diagnostic log of operation stages and status codes. It excludes tokens and workout details, is excluded from backups, and can be read through Xcode for this trial.")
                }
                Section("Your Apple and file-provider settings") {
                    Text("Apple Health may sync your data through iCloud. A file selected from iCloud Drive or another provider may be downloaded by Files. Those are services you control; this app does not upload your activities.")
                }
                Section("Your control") {
                    Text("You can revoke Health permissions in Settings. Undo removes the records this app created for an import, including associated samples. Uninstalling the app removes its local import history but does not delete workouts from Health.")
                    Text("Forget connection removes this app’s Strava tokens and preview. Because this trial reuses Stitch’s developer app, revoking its access on Strava also affects Stitch and any other app using that grant. Undo unwanted Health imports before uninstalling.")
                    Link("Manage connected apps on Strava", destination: URL(string: "https://www.strava.com/settings/apps")!)
                    Link("Project and support", destination: URL(string: "https://github.com/barclayd/strava-apple-health-sync")!)
                }
            }
            .navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
