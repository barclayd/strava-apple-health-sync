import SwiftUI

@main struct HealthImportApp: App {
    @State private var model = ImportModel()
    @State private var strava = StravaConnection()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if StravaDiagnosticView.requested { StravaDiagnosticView(strava: strava) }
            else { importView }
            #else
            importView
            #endif
        }
    }

    private var importView: some View {
        ImportView(model: model, strava: strava)
            .tint(ImportTheme.accent)
            .task { if !ActivityLibrary.preview { await strava.restore() } }
            .onOpenURL { url in
                Task {
                    guard !model.historyRunning else { return }
                    if url.scheme == "healthimport-strava" { await strava.callback(url) }
                }
            }
    }
}
