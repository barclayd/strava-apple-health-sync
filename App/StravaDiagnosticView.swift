#if DEBUG
import SwiftUI
import ActivityImportCore

/// Xcode-only, read-only reproduction. It cannot request Health access or save a workout.
struct StravaDiagnosticView: View {
    @Bindable var strava: StravaConnection
    @State private var message = "Checking Strava timing…"
    @State private var finished = false

    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--diagnose-strava-offset") }

    var body: some View {
        VStack(spacing: 16) {
            if !finished { ProgressView() }
            Text(message)
            Text("Read-only check. No Health data will be changed.").foregroundStyle(.secondary)
        }.padding().task { await check() }
    }

    private func check() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--diagnose-strava-offset"),
              arguments.indices.contains(index + 1), let offset = Int(arguments[index + 1]),
              (0..<50).contains(offset) else {
            message = "Choose an offset in the latest 50 activities."; finished = true; return
        }
        await strava.restore()
        await AppDiagnostics.shared.record(.readOnlyCheckStarted)
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle; finished = true }
        do {
            let page = try await strava.activityPage(query: ActivityQuery(before: Date()), page: 1, size: 50)
            guard page.indices.contains(offset) else { throw ImportProblem("That activity is not available.") }
            _ = try await strava.historyActivity(id: page[offset].id)
            await AppDiagnostics.shared.record(.readOnlyCheckCompleted)
            message = "Timing check passed. Nothing was imported."
        } catch {
            await AppDiagnostics.shared.record(.readOnlyCheckFailed)
            message = error.localizedDescription
        }
    }
}
#endif
