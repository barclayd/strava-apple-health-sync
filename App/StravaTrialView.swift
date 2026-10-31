import SwiftUI
import ActivityImportCore

struct StravaTrialSection: View {
    @Bindable var strava: StravaConnection
    @Bindable var model: ImportModel
    @State private var review = false
    @State private var forget = false

    var body: some View {
        Section {
            if model.stravaTrialComplete {
                Label("Trial workout imported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Check its date, distance, duration and available samples in Apple Health. Full-history sync comes after this check.")
                    .foregroundStyle(.secondary)
            }
            if strava.connected {
                Label("Connected with Strava", systemImage: "checkmark.circle")
                DatePicker("Trial date", selection: $strava.trialDate, in: ...Date(), displayedComponents: .date)
                    .onChange(of: strava.trialDate) { _, _ in strava.activities = []; strava.fetched = false }
                Button { Task { await strava.fetch() } } label: {
                    Label("Find activities", systemImage: "arrow.clockwise")
                }.accessibilityIdentifier("fetchStrava")
                if strava.fetched && strava.activities.isEmpty {
                    Text("No activities found on this date. Choose another day or check your Strava permissions.")
                        .foregroundStyle(.secondary)
                }
                ForEach(strava.activities) { activity in
                    Button {
                        Task { if await strava.preview(activity, into: model) { review = true } }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: activity.sport?.symbol ?? "figure.mixed.cardio").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activity.name).font(.headline)
                                Text("\(activity.sportType) · \(activity.startDate.formatted(date: .omitted, time: .shortened)) · \((activity.distance / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if activity.sport == nil { Text("This trial supports runs and rides").font(.caption) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 6)
                    }.disabled(activity.sport == nil)
                }
                Button("Forget connection on this device", role: .destructive) { forget = true }
            } else if strava.authorising {
                Label("Finish connecting in Strava", systemImage: "person.crop.circle.badge.clock")
                Button("Cancel connection") { strava.cancel() }
            } else {
                Button { strava.connect() } label: {
                    Text("Connect with Strava").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.99, green: 0.30, blue: 0.01))
                .accessibilityIdentifier("connectStrava")
                .disabled(strava.configuration == nil)
                if strava.configuration == nil {
                    Text("Strava isn’t configured in this build yet. Local developer setup is described in the project README.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Try one workout") } footer: {
            Text("Reads your activities, including private activities, directly from Strava. Yesterday is selected for the trial. Choose one workout to review before saving to Health. No activities or Health data are uploaded by this app.")
        }
        .navigationDestination(isPresented: $review) {
            if let activity = model.activities.first { ActivityView(activity: activity, model: model) }
        }
        .confirmationDialog("Forget this device’s Strava connection?", isPresented: $forget, titleVisibility: .visible) {
            Button("Forget local connection", role: .destructive) {
                Task {
                    await strava.forget()
                    if !strava.connected && model.stravaSource != nil {
                        model.activities = []; model.stravaSource = nil
                    }
                }
            }
        } message: {
            Text("Removes tokens and the Strava preview from this app. Imported Health records remain available in import history for undo. The shared Stitch connection is not revoked.")
        }
    }
}
