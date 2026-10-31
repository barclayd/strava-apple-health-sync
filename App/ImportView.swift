import SwiftUI
import UniformTypeIdentifiers
import ActivityImportCore

struct ImportView: View {
    @Bindable var model: ImportModel
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
                        Text("Your Strava history, imported on your device. Choose a file, review the details, then save to Health.")
                            .font(.body).foregroundStyle(.secondary)
                        Label("No account. No uploads by this app.", systemImage: "lock.shield")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.indigo)
                    }.padding(.vertical, 14)
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                Section {
                    Button { showFiles = true } label: {
                        Label("Choose TCX files", systemImage: "doc.badge.plus").font(.headline).padding(.vertical, 8)
                    }.accessibilityIdentifier("chooseFiles")
                    Button { Task { await model.loadExample() } } label: {
                        Label("Preview a synthetic example", systemImage: "play.circle")
                    }.accessibilityIdentifier("loadExample")
                } header: { Text("Start with an export") } footer: {
                    Text("POC · TCX runs and rides, up to 20 files. FIT, GPX and ZIP archives will need a later importer.")
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
                        Button("Clear preview", role: .destructive) { model.activities = []; model.example = false }
                    } header: { Text(model.example ? "Synthetic example" : "Ready to review") } footer: {
                        if model.example {
                            Text(model.canImportExample ? "Invented data. Imports here use only this simulator’s Health store." : "Invented data for a read-only preview. Choose your own file to import.")
                        } else { Text("Files are read in memory. The app does not keep a copy of your export.") }
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
                        Text("Undo removes this app’s workout, distance, heart rate and route for that import. Keep the app installed until you’ve checked the result.")
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
        .overlay { if model.busy { ProgressView("Working on device…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .disabled(model.busy)
        .alert("Health Import", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct ActivityView: View {
    let activity: Activity
    @Bindable var model: ImportModel
    @State private var reviewed = false
    @State private var confirm = false

    private var alreadyImported: Bool { model.records.contains { $0.activityID == activity.id } }

    var body: some View {
        List {
            Section {
                LabeledContent("Activity", value: activity.sport.title)
                LabeledContent("Started", value: activity.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Timer duration", value: duration(activity.duration))
                LabeledContent("Elapsed time", value: duration(activity.end.timeIntervalSince(activity.start)))
                LabeledContent("Distance", value: "\((activity.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                LabeledContent("Heart-rate samples", value: "\(activity.heartRatePoints.count)")
                LabeledContent("Route points", value: "\(activity.routePoints.count)")
            } header: { Text(model.example ? "Synthetic activity" : "What will be imported") } footer: {
                Text("Original timestamps and timer duration are preserved. Calories, cadence and power are not imported in this POC. TCX calories do not specify active versus total energy.")
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
                .disabled(!reviewed || alreadyImported || model.busy || model.journalError != nil || (model.example && !model.canImportExample))
            } footer: {
                Text("Health will list Health Import as the source. You can undo the import from this app’s history.")
            }
        }
        .navigationTitle("Review workout").navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .confirmationDialog("Save this workout and its samples to Health?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Save to Health") { Task { await model.importActivity(activity) } }
        } message: { Text("Nothing is uploaded by Health Import. Your Apple Health iCloud settings still apply.") }
    }

    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("What this app does") {
                    Text("Reads only export files you select. Parsing and duplicate checks run on your device.")
                    Text("Writes the selected workout and available distance, heart rate and route to Apple Health with your permission.")
                    Text("Keeps a small import history on this device for duplicate protection and undo. That history is excluded from device backups. Original files are not copied into the app.")
                }
                Section("What we collect") {
                    Text("Nothing. There is no account, server, analytics, advertising or crash-reporting service in this app. It contains no networking code or third-party SDKs.")
                }
                Section("Your Apple and file-provider settings") {
                    Text("Apple Health may sync your data through iCloud. A file selected from iCloud Drive or another provider may be downloaded by Files. Those are services you control; this app does not upload your activities.")
                }
                Section("Your control") {
                    Text("You can revoke Health permissions in Settings. Undo removes the records this app created for an import, including associated samples. Uninstalling the app removes its local import history but does not delete workouts from Health.")
                }
            }
            .navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
