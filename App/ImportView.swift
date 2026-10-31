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
    @State private var showMonth = false
    @State private var forget = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var connected: Bool { ActivityLibrary.preview ? library.previewConnected : strava.connected }
    private var locked: Bool { library.active || model.busy || strava.busy }
    private var needsCleanup: Bool { model.records.contains { !$0.completed } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if connected { connectedContent } else { welcome }
                    if let error = model.journalError { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                    if needsCleanup {
                        Button("An interrupted import needs cleanup", systemImage: "exclamationmark.circle") { showHistory = true }
                            .font(.subheadline)
                    }
                    if let message = strava.message ?? model.message, !library.running {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(ImportTheme.background)
            .navigationTitle("Health Import").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import history", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        Button("Privacy", systemImage: "lock.shield") { showPrivacy = true }
                        if connected {
                            Button("Refresh", systemImage: "arrow.clockwise") { library.load(strava: strava, model: model) }
                            Button("Disconnect Strava", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { forget = true }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                        .accessibilityLabel("Options").disabled(locked)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $showHistory) { ImportHistoryView(model: model) }
            .sheet(isPresented: $showPrivacy) { PrivacyView() }
            .sheet(isPresented: $showMonth) { MonthPicker(month: $library.month) }
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
                if ActivityLibrary.preview && ProcessInfo.processInfo.arguments.contains("--preview-connected") { library.previewConnected = true }
                if connected && !library.loaded { library.load(strava: strava, model: model) }
            }
            .onChange(of: connected) { _, value in
                if value && !library.loaded { library.load(strava: strava, model: model) }
            }
            .onChange(of: library.selection.scope) { _, _ in reloadSelection() }
            .onChange(of: library.selection.start) { _, _ in if library.selection.scope == .dates { reloadSelection() } }
            .onChange(of: library.selection.end) { _, _ in if library.selection.scope == .dates { reloadSelection() } }
            .onChange(of: library.selection.ids) { _, _ in library.selectionChanged() }
            .onChange(of: library.month) { _, _ in if library.selection.scope == .individual { reloadSelection() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { library.pause() }
                if phase == .active && !connected && !strava.authorising && !strava.busy && !ActivityLibrary.preview {
                    Task { await strava.restore() }
                }
            }
        }
    }

    private func reloadSelection() {
        library.selectionChanged()
        library.load(strava: strava, model: model)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "arrow.down.heart").font(.system(size: 42, weight: .light)).foregroundStyle(ImportTheme.accent)
                .accessibilityHidden(true).padding(.top, 48)
            Text("Your rides.\nIn Health.").font(.system(size: 42, weight: .semibold, design: .rounded)).tracking(-1)
            Text("Bring your Strava history into Apple Health.\nDirectly on your device.")
                .font(.body).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    private var scopePicker: some View {
        Picker("Import", selection: $library.selection.scope) {
            ForEach(ImportScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("importScope")
    }

    @ViewBuilder private var connectedContent: some View {
        HStack {
            Text("Import from Strava").font(.title2.weight(.semibold))
            Spacer()
            if ActivityLibrary.preview { Text("Demo").font(.caption).foregroundStyle(.secondary) }
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize { scopePicker.pickerStyle(.menu) }
            else { scopePicker.pickerStyle(.segmented) }
            if library.selection.scope == .individual { monthNavigation }
            if library.selection.scope == .dates {
                VStack(spacing: 12) {
                    DatePicker("From", selection: $library.selection.start, in: ...library.selection.end, displayedComponents: .date)
                        .accessibilityIdentifier("startDate")
                    DatePicker("To", selection: $library.selection.end, in: library.selection.start...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("endDate")
                }.font(.subheadline)
            }
        }.disabled(library.running || model.busy)

        if library.importer != nil { importProgress }
        else {
            if library.loading {
                HStack(spacing: 10) { ProgressView(); Text("Loading rides…").font(.subheadline).foregroundStyle(.secondary) }
                    .padding(.vertical, 24)
            } else if let error = library.browseError {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry") { library.load(strava: strava, model: model, page: library.browsePage, reset: false) }
                }
            } else if library.loaded {
                if library.selection.scope == .all {
                    HStack {
                        Text("Latest rides").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse months") { library.selection.scope = .individual }.font(.subheadline)
                    }
                }
                if library.activities.isEmpty {
                    Text(library.canBrowseOlder ? "No supported rides on this page." : library.browsePage > 1 ? "No more rides in this period." : "No rides in this period.")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
                } else { activityRows }
                if library.selection.scope != .all { pageNavigation }
                if library.selection.scope == .individual && !library.selection.ids.isEmpty {
                    HStack {
                        Text("\(library.selection.ids.count) selected across months").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { library.selection.ids = [] }.font(.caption)
                    }
                }
            }
        }
    }

    private var monthNavigation: some View {
        HStack {
            Button { library.month = Calendar.current.date(byAdding: .month, value: -1, to: library.month)! } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel("Previous month")
            Spacer()
            Button { showMonth = true } label: {
                HStack(spacing: 8) {
                    Text(library.month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }.frame(minHeight: 44)
            }.accessibilityLabel("Choose month and year").accessibilityIdentifier("chooseMonth")
            Spacer()
            Button { library.month = Calendar.current.date(byAdding: .month, value: 1, to: library.month)! } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }.accessibilityLabel("Next month")
                .disabled(Calendar.current.isDate(library.month, equalTo: ActivityLibrary.now, toGranularity: .month) || library.month > ActivityLibrary.now)
        }
    }

    private var activityRows: some View {
        let groups = Dictionary(grouping: library.activities) { Calendar.current.dateInterval(of: .month, for: $0.startDate)!.start }
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                VStack(alignment: .leading, spacing: 0) {
                    if library.selection.scope != .individual {
                        Text(month.formatted(.dateTime.month(.wide).year())).font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary).padding(.bottom, 6)
                    }
                    ForEach(groups[month] ?? []) { activity in
                        let imported = model.hasImported(stravaID: activity.id) || library.matchedVisibleIDs.contains(activity.id)
                        if library.selection.scope == .individual && !imported {
                            Button {
                                if !library.selection.ids.insert(activity.id).inserted { library.selection.ids.remove(activity.id) }
                            } label: { activityRow(activity, imported: false) }
                            .buttonStyle(.plain).accessibilityIdentifier("select-\(activity.id)")
                            .accessibilityAddTraits(library.selection.ids.contains(activity.id) ? [.isSelected] : [])
                        } else { activityRow(activity, imported: imported) }
                        if activity.id != groups[month]?.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func activityRow(_ activity: StravaActivity, imported: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Text(activity.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if imported {
                Image(systemName: "checkmark").foregroundStyle(ImportTheme.accent).accessibilityLabel("Imported")
            } else if library.selection.scope == .individual {
                Image(systemName: library.selection.ids.contains(activity.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(ImportTheme.accent).accessibilityHidden(true)
            }
        }.padding(.vertical, 16).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    private var pageNavigation: some View {
        HStack {
            Button("Newer") { library.load(strava: strava, model: model, page: library.browsePage - 1, reset: false) }
                .disabled(library.browsePage == 1)
            Spacer()
            Text("Page \(library.browsePage)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Older") { library.load(strava: strava, model: model, page: library.browsePage + 1, reset: false) }
                .disabled(!library.canBrowseOlder)
        }.font(.subheadline).frame(minHeight: 44)
    }

    private var importProgress: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if library.running { ProgressView() }
                else { Image(systemName: library.finished ? "checkmark.circle.fill" : "pause.circle").foregroundStyle(ImportTheme.accent) }
                Text(library.finished ? "Import complete" : library.running ? "Importing…" : "Import paused").font(.headline)
            }
            Text("\(library.importedCount) imported · \(library.skippedCount) skipped").font(.subheadline).foregroundStyle(.secondary)
            if library.running, let month = library.currentMonth {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.importError {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                if library.canSkip && !needsCleanup { Button("Skip this ride") { library.skip() }.font(.subheadline) }
            }
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if connected {
                let disabled = library.loading || (!library.running && (model.busy || model.journalError != nil || needsCleanup || (library.selection.scope == .individual && library.selection.ids.isEmpty && !library.finished))) || (library.running && library.pauseRequested)
                Button {
                    if library.running { library.pause() }
                    else if library.finished { library.selection.ids = []; library.selectionChanged(); library.load(strava: strava, model: model) }
                    else { Task { await library.run(strava: strava, model: model) } }
                } label: {
                    Text(importLabel).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(ImportButtonStyle()).disabled(disabled).accessibilityIdentifier("importSelection")
                Text(library.running ? "Keep the app open" : "Direct to Apple Health")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    if ActivityLibrary.preview { library.previewConnected = true }
                    else { strava.connect() }
                } label: {
                    HStack(spacing: 10) {
                        if strava.busy || strava.authorising { ProgressView().tint(.white) }
                        Text(strava.authorising ? "Connecting…" : "Connect with Strava")
                    }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).tint(ImportTheme.orange)
                    .disabled(strava.busy || strava.authorising || (!ActivityLibrary.preview && strava.configuration == nil))
                    .accessibilityIdentifier("connectStrava")
                if strava.authorising { Button("Cancel") { strava.cancel() }.font(.caption) }
                else if strava.configuration == nil && !ActivityLibrary.preview { Text("Strava isn’t configured in this build").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
            .frame(maxWidth: 620).frame(maxWidth: .infinity).background(.bar)
    }

    private var importLabel: String {
        if library.running { return library.pauseRequested ? "Pausing…" : "Pause import" }
        if library.finished { return "Done" }
        if library.hasPending { return "Resume import" }
        switch library.selection.scope {
        case .all: return "Import all history"
        case .dates: return "Import date range"
        case .individual:
            let count = library.selection.ids.count
            return count == 0 ? "Select rides" : "Import \(count) \(count == 1 ? "ride" : "rides")"
        }
    }
}

private struct MonthPicker: View {
    @Binding var month: Date
    @State private var year = Calendar.current.component(.year, from: ActivityLibrary.now)
    @State private var monthNumber = Calendar.current.component(.month, from: ActivityLibrary.now)
    @Environment(\.dismiss) private var dismiss
    private let calendar = Calendar.current
    var body: some View {
        NavigationStack {
            HStack {
                Picker("Month", selection: $monthNumber) {
                    ForEach(1...12, id: \.self) { value in Text(calendar.monthSymbols[value - 1]).tag(value) }
                }.pickerStyle(.wheel)
                Picker("Year", selection: $year) {
                    ForEach((1970...calendar.component(.year, from: Date())).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }.pickerStyle(.wheel)
            }.padding(.horizontal)
                .navigationTitle("Choose month").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show rides") {
                            month = calendar.date(from: DateComponents(year: year, month: monthNumber, day: 1))!
                            dismiss()
                        }.disabled(calendar.date(from: DateComponents(year: year, month: monthNumber, day: 1))! > Date())
                    }
                }
                .onAppear { year = calendar.component(.year, from: month); monthNumber = calendar.component(.month, from: month) }
        }.presentationDetents([.height(340), .large]).presentationDragIndicator(.visible)
    }
}
private struct ImportHistoryView: View {
    @Bindable var model: ImportModel
    @State private var undoRecord: ImportRecord?
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.records.isEmpty {
                    ContentUnavailableView("No imports yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Your imported workouts will appear here."))
                }
                ForEach(Array(model.records.reversed().dropFirst(page * 20).prefix(20))) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(record.sport.title, systemImage: record.sport.symbol).font(.headline)
                        Text(record.start.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                        Button(record.completed ? "Undo import" : "Undo interrupted import", role: .destructive) { undoRecord = record }
                    }.padding(.vertical, 6)
                }
                if model.records.count > 20 {
                    HStack {
                        Button("Newer") { page -= 1 }.disabled(page == 0)
                        Spacer()
                        Button("Older") { page += 1 }.disabled((page + 1) * 20 >= model.records.count)
                    }
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
