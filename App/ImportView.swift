import SwiftUI
import ActivityImportCore

// A restrained palette that keeps the primary action clear in light and dark mode.
enum ImportTheme {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.48, green: 0.88, blue: 0.70, alpha: 1)
        : UIColor(red: 0.08, green: 0.33, blue: 0.26, alpha: 1) })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let orange = Color(red: 0.94, green: 0.27, blue: 0.01)
}

struct ImportView: View {
    @Bindable var model: ImportModel
    @Bindable var strava: StravaConnection
    @State private var library = ActivityLibrary()
    @State private var showHistory = false
    @State private var showPrivacy = false
    @State private var forget = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var connected: Bool { ActivityLibrary.preview ? library.previewConnected : strava.connected }
    private var locked: Bool { library.active || model.busy || strava.busy }
    private var needsCleanup: Bool { model.records.contains { !$0.completed } }
    private var ridesOnly: Bool { library.activities.allSatisfy { $0.sport == .cycling } }
    private var noun: String { ridesOnly ? "rides" : "activities" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let error = model.journalError { notice(error) }
                    if needsCleanup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("One import needs attention").font(.headline)
                            Text("Undo the interrupted import to continue.").foregroundStyle(.secondary)
                            Button("Open import history") { showHistory = true }.font(.subheadline.bold())
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ImportTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if connected { connectedContent } else { welcome }
                    if let message = strava.message ?? model.message {
                        notice(message) { strava.message = nil; model.message = nil }
                    }
                }
                .padding(.horizontal, 24).padding(.top, connected ? 20 : 36).padding(.bottom, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(ImportTheme.background)
            .navigationTitle("Health Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import history", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        Button("Privacy", systemImage: "lock.shield") { showPrivacy = true }
                        if connected {
                            Button("Refresh activities", systemImage: "arrow.clockwise") { library.load(strava: strava, model: model) }
                            Button("Disconnect Strava", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { forget = true }
                        }
                    } label: { Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 36, height: 36) }
                    .accessibilityLabel("Options").disabled(locked)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $showHistory) { ImportHistoryView(model: model) }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
            .confirmationDialog("Disconnect Strava on this device?", isPresented: $forget, titleVisibility: .visible) {
                Button("Disconnect Strava", role: .destructive) {
                    Task {
                        if ActivityLibrary.preview { library.previewConnected = false }
                        else { await strava.forget() }
                        if !connected { library.clear() }
                    }
                }
            } message: { Text("Your imported workouts stay in Health. Your other Strava connections stay connected.") }
            .task {
                if ActivityLibrary.preview && ProcessInfo.processInfo.arguments.contains("--preview-connected") {
                    library.previewConnected = true
                }
                if connected && !library.loaded { library.load(strava: strava, model: model) }
            }
            .onChange(of: connected) { _, value in
                if value && !library.loaded { library.load(strava: strava, model: model) }
            }
            .onChange(of: library.selection) { _, _ in library.selectionChanged() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { library.pause() } }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 18) {
                Image(systemName: "bicycle").foregroundStyle(ImportTheme.orange)
                Image(systemName: "arrow.right").font(.title3).foregroundStyle(.tertiary)
                Image(systemName: "heart.fill").foregroundStyle(ImportTheme.accent)
            }.font(.system(size: 36, weight: .medium)).accessibilityHidden(true).padding(.top, 16)
            VStack(alignment: .leading, spacing: 18) {
                Text("Every ride.\nOne place.")
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .tracking(-1.5).fixedSize(horizontal: false, vertical: true)
                Text("Bring your Strava history\ninto Apple Health.")
                    .font(.title3).foregroundStyle(.secondary).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 22) {
                feature("Your history, your choice", subtitle: "All your rides, a few favourites or a date range.", symbol: "checklist")
                feature("Straight to Health", subtitle: "Calories, routes and recorded ride data.", symbol: "heart.text.clipboard")
                feature("Private by design", subtitle: "Processed on your device. No app server.", symbol: "lock.shield")
            }.padding(.top, 8)
            if ActivityLibrary.preview { Text("Demo · invented rides").font(.caption).foregroundStyle(.secondary) }
        }.padding(.bottom, 8)
    }

    private func feature(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3).foregroundStyle(ImportTheme.accent).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ActivityLibrary.preview ? "Demo · invented rides" : "Connected to Strava", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(ImportTheme.accent)
            Text("Your \(noun),\nin Apple Health.")
                .font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = library.error {
            VStack(alignment: .leading, spacing: 12) {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                if library.queue == nil {
                    Button("Retry") { library.load(strava: strava, model: model) }.font(.subheadline.bold())
                } else if !needsCleanup && !library.running {
                    Button("Skip this activity") { library.skip() }.font(.subheadline.bold())
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(ImportTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        if library.loading {
            HStack(spacing: 12) {
                ProgressView()
                Text(library.scannedCount == 0 ? "Loading your activities…" : "Found \(library.scannedCount) activities…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 28)
        } else if library.loaded {
            selectionControls
            if let queue = library.queue {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: library.finished ? "checkmark.circle.fill" : "arrow.down.heart")
                            .foregroundStyle(ImportTheme.accent)
                        Text(library.finished ? "Import complete" : library.running ? "Importing to Health" : "Import paused")
                            .font(.headline)
                        Spacer()
                        Text("\(library.outcomes.count)/\(queue.activities.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !library.finished {
                        ProgressView(value: Double(library.outcomes.count), total: Double(max(1, queue.activities.count))).tint(ImportTheme.accent)
                    }
                    Text(progressSummary).font(.subheadline).foregroundStyle(.secondary)
                }.padding(18).background(ImportTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement(children: .combine)
            }
            if library.visible.isEmpty {
                ContentUnavailableView(library.activities.isEmpty ? "No rides yet" : "No rides in this period",
                    systemImage: "bicycle", description: Text(library.activities.isEmpty ? "Your Strava runs and rides will appear here." : "Try a different start or end date."))
            } else { activityRows }
        }

    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                scopePicker.pickerStyle(.menu)
            } else {
                scopePicker.pickerStyle(.segmented)
            }
            if library.selection.scope == .dates {
                VStack(spacing: 12) {
                    DatePicker("From", selection: $library.selection.start, in: ...library.selection.end, displayedComponents: .date)
                        .accessibilityIdentifier("startDate")
                    Divider()
                    DatePicker("To", selection: $library.selection.end, in: library.selection.start...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("endDate")
                }.font(.subheadline).padding(18).background(ImportTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            HStack {
                Text(library.selection.scope == .individual ? "Select your \(noun)" : "\(library.visible.count) \(noun)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if library.selection.scope == .individual && !library.selection.ids.isEmpty {
                    Button("Clear") { library.selection.ids = [] }.font(.subheadline)
                } else if let first = library.visible.last?.startDate, let last = library.visible.first?.startDate {
                    Text(first.formatted(.dateTime.year()) == last.formatted(.dateTime.year())
                         ? first.formatted(.dateTime.year()) : "\(first.formatted(.dateTime.year()))–\(last.formatted(.dateTime.year()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(library.running || model.busy)
    }

    private var scopePicker: some View {
        Picker("Import selection", selection: $library.selection.scope) {
            ForEach(ImportScope.allCases, id: \.self) { scope in Text(scope.rawValue).tag(scope) }
        }.accessibilityIdentifier("importScope")
    }

    private var activityRows: some View {
        let imported = Set(model.records.filter(\.completed).map(\.activityID))
        let visible = library.visible
        return LazyVStack(spacing: 0) {
            ForEach(visible) { activity in
                let exists = imported.contains("strava-v1-\(activity.id)") || library.outcomes[activity.id] == .duplicate
                let selected = library.selection.scope != .individual || library.selection.ids.contains(activity.id)
                if library.selection.scope == .individual && !exists {
                    Button {
                        if !library.selection.ids.insert(activity.id).inserted { library.selection.ids.remove(activity.id) }
                    } label: { activityRow(activity, selected: selected, imported: false) }
                    .buttonStyle(.plain).disabled(library.running || model.busy)
                    .accessibilityIdentifier("select-\(activity.id)")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                } else { activityRow(activity, selected: selected, imported: exists) }
                if activity.id != visible.last?.id { Divider().padding(.leading, 68) }
            }
        }.background(ImportTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func activityRow(_ activity: StravaActivity, selected: Bool, imported: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: activity.sport?.symbol ?? "bicycle")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(ImportTheme.accent)
                .frame(width: 36, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text("\(activity.startDate.formatted(.dateTime.day().month(.abbreviated).year())) · \((activity.distance / 1000).formatted(.number.precision(.fractionLength(1)))) km")
                    .font(.caption).foregroundStyle(.secondary)
                if imported { Text("In Health").font(.caption.weight(.medium)).foregroundStyle(ImportTheme.accent) }
            }
            Spacer(minLength: 2)
            Image(systemName: imported ? "checkmark.seal.fill" : selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(imported || selected ? ImportTheme.accent : Color.secondary.opacity(0.4))
                .accessibilityHidden(true)
        }.padding(.horizontal, 16).padding(.vertical, 17).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    private var progressSummary: String {
        let imported = library.outcomes.values.filter { $0 == .imported }.count
        let skipped = library.outcomes.count - imported
        if library.running { return library.pauseRequested ? "Finishing the current activity…" : "\(library.outcomes.count) of \(library.queue?.activities.count ?? 0) processed" }
        return "\(imported) imported" + (skipped > 0 ? " · \(skipped) skipped" : "")
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if connected {
                let count = library.pending(records: model.records).count
                let disabled = library.loading || (!library.running && (model.busy || (count == 0 && !library.hasPending) || model.journalError != nil || needsCleanup)) || library.pauseRequested && library.running
                Button {
                    if library.running { library.pause() }
                    else { Task { await library.run(strava: strava, model: model) } }
                } label: {
                    HStack(spacing: 10) {
                        if library.running && library.pauseRequested { ProgressView().tint(ImportTheme.background) }
                        else { Image(systemName: library.running ? "pause.fill" : "arrow.down.heart") }
                        Text(library.running ? (library.pauseRequested ? "Pausing…" : "Pause import")
                            : library.hasPending ? "Resume import"
                            : count > 0 ? "Import \(count) \(count == 1 ? (ridesOnly ? "ride" : "activity") : noun)"
                            : library.selection.scope == .individual && library.selection.ids.isEmpty ? "Select rides to import"
                            : library.finished ? "Up to date" : "Import to Apple Health")
                    }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(ImportButtonStyle())
                .disabled(disabled)
                .accessibilityIdentifier("importSelection")
                Text(library.running ? "Keep the app open while importing" : "Saved directly to Apple Health")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    if ActivityLibrary.preview { library.previewConnected = true }
                    else { strava.connect() }
                } label: {
                    HStack(spacing: 10) {
                        if strava.busy || strava.authorising { ProgressView().tint(.white) }
                        Text(strava.authorising ? "Connecting to Strava…" : "Connect with Strava")
                    }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).tint(ImportTheme.orange)
                    .disabled(strava.busy || strava.authorising || (!ActivityLibrary.preview && strava.configuration == nil))
                    .accessibilityIdentifier("connectStrava")
                if strava.authorising {
                    Button("Cancel") { strava.cancel() }.font(.caption)
                } else {
                    Text(strava.configuration == nil && !ActivityLibrary.preview ? "Strava isn’t configured in this build" : "Connect once. Import whenever you’re ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
            .background(.bar)
    }

    private func notice(_ text: String, dismiss: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            if let dismiss { Button("Dismiss", action: dismiss).font(.subheadline.bold()) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ImportTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ImportHistoryView: View {
    @Bindable var model: ImportModel
    @State private var undoRecord: ImportRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.records.isEmpty {
                    ContentUnavailableView("No imports yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Your imported workouts will appear here."))
                }
                ForEach(model.records.reversed()) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(record.sport.title, systemImage: record.sport.symbol).font(.headline)
                        Text(record.start.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                        Button(record.completed ? "Undo import" : "Undo interrupted import", role: .destructive) { undoRecord = record }
                    }.padding(.vertical, 6)
                }
                if let message = model.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            }.navigationTitle("Import history").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(model.busy) } }
                .disabled(model.busy).interactiveDismissDisabled(model.busy)
                .confirmationDialog("Remove this import from Apple Health?", isPresented: Binding(
                    get: { undoRecord != nil }, set: { if !$0 { undoRecord = nil } }), titleVisibility: .visible) {
                    if let record = undoRecord {
                        Button("Remove imported data", role: .destructive) {
                            Task { await model.undo(record) }; undoRecord = nil
                        }
                    }
                } message: { Text("Only this app’s workout and associated samples will be removed.") }
        }
    }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("On your device") {
                    Text("Health Import reads activities directly from Strava and saves your selection to Apple Health. There is no app server, analytics or advertising. Your activity data is held in memory, without a disk cache.")
                    Text("Available Strava calories are saved as active energy. Recorded measurements and original timestamps are preserved, with estimated pauses for detected breaks.")
                }
                Section("Your control") {
                    Text("A protected import history on this device helps prevent duplicates and lets you undo this app’s imports. Health permissions can be changed in Settings. Duplicate checks can only see workouts you allow Health Import to read.")
                    Text("Disconnect removes this app’s Strava tokens. Imported workouts stay in Health. Undo unwanted imports before uninstalling the app.")
                }
                Section("Your settings") {
                    Text("Apple Health may sync through iCloud according to your settings. Strava handles sign-in and activity requests under its own privacy policy. No activities or Health data are uploaded by Health Import.")
                }
            }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ImportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(enabled ? Color(uiColor: .systemBackground) : Color.secondary)
            .background(enabled ? ImportTheme.accent : Color(uiColor: .quaternarySystemFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
