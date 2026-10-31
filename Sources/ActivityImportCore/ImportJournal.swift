import Foundation

public struct ImportRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let activityID: String
    public let sport: Sport
    public let start: Date
    public var completed: Bool

    public init(activity: Activity) {
        id = UUID(); activityID = activity.id; sport = activity.sport; start = activity.start; completed = false
    }
}

/// Write-ahead log: a record is durable before HealthKit is touched. Failed writes leave memory unchanged.
@MainActor public final class ImportJournal {
    public private(set) var records: [ImportRecord]
    private let file: URL

    public init(directory: URL) throws {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        file = directory.appendingPathComponent("imports.json")
        records = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([ImportRecord].self, from: Data(contentsOf: file)) : []
    }

    public func append(_ record: ImportRecord) throws { try persist(records + [record]) }
    public func complete(_ id: UUID) throws {
        try persist(records.map { record in
            var result = record
            if result.id == id { result.completed = true }
            return result
        })
    }
    public func remove(_ id: UUID) throws { try persist(records.filter { $0.id != id }) }

    private func persist(_ updated: [ImportRecord]) throws {
        let data = try JSONEncoder().encode(updated)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        records = updated
    }
}
