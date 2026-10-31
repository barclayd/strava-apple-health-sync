import SwiftUI

@main struct HealthImportApp: App {
    @State private var model = ImportModel()

    var body: some Scene {
        WindowGroup {
            ImportView(model: model)
                .tint(.indigo)
                .onOpenURL { url in Task { await model.load([url]) } }
        }
    }
}
