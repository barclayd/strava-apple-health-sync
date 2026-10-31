import Foundation

/// Debug-only, bounded diagnostics. Events are an enum so payloads, URLs and tokens cannot be logged.
actor AppDiagnostics {
    static let shared = AppDiagnostics()
    enum Event: String {
        case appStarted, connectionRestored, connectionRestoreFailed
        case authorisationStarted, nativeAuthorisationOpened, webAuthorisationOpened
        case callbackReceived, callbackValidated, connectionSaved, authorisationFailed, authorisationCancelled
        case tokenRequest, activityListRequest, activityDetailRequest, activityStreamsRequest
        case responseReceived, requestFailed, activitiesLoaded, previewLoaded, previewFailed, connectionForgotten
        case healthPermissionRequested, healthPermissionGranted, duplicateBlocked
        case healthWriteStarted, healthWriteCompleted, importFailed, rollbackCompleted, rollbackFailed
        case streamTimestampInvalid, streamTimestampDuplicate, streamTimestampOutOfOrder
        case streamTimestampPastEndWithinSecond, streamTimestampPastEndWithinMinute, streamTimestampPastEnd
        case streamEndRoundingAccepted
        case readOnlyCheckStarted, readOnlyCheckCompleted, readOnlyCheckFailed
    }
    private var lines: [String] = []

    func record(_ event: Event, status: Int? = nil) {
        #if DEBUG
        let suffix = status.map { " status=\($0)" } ?? ""
        let line = "\(Date().ISO8601Format()) \(event.rawValue)\(suffix)"
        lines.append(line)
        lines = Array(lines.suffix(200))
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent("health-import-diagnostics.log")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { /* Diagnostics never block sign-in or Health operations. */ }
        #endif
    }
}
