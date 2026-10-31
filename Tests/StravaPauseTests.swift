import Foundation
import Testing
@testable import ActivityImportCore

private func ride(_ modify: (inout [String: Any]) -> Void = { _ in }) throws -> Activity {
    let detail = try #require(Bundle.module.url(forResource: "synthetic-paused-ride", withExtension: "json", subdirectory: "Fixtures"))
    let url = try #require(Bundle.module.url(forResource: "synthetic-paused-ride-streams", withExtension: "json", subdirectory: "Fixtures"))
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    modify(&json)
    let streams = try StravaJSON.decode(StravaStreams.self, from: JSONSerialization.data(withJSONObject: json))
    return try StravaJSON.decode(StravaActivity.self, from: Data(contentsOf: detail)).activity(streams: streams)
}

@Test func detectedBreaksPreserveTimestampsAndExcludeOnlyInactiveTime() throws {
    let activity = try ride()
    #expect(activity.pauses == [DateInterval(start: activity.start.addingTimeInterval(60), duration: 180)])
    #expect(activity.duration == 300)
    #expect(activity.workoutDuration == 120)
    #expect(activity.points.map { $0.date.timeIntervalSince(activity.start) } == [0,10,20,30,40,50,60,240,250,260,270,280,290,300])
    var elapsedOnly = activity
    elapsedOnly.pauses = []
    #expect(elapsedOnly.workoutDuration == 300)
    #expect(elapsedOnly.id == activity.id)
}

@Test func sparseDownsampledAndMovingGapsDoNotBecomePauses() throws {
    let downsampled = try ride { json in
        for key in Array(json.keys) {
            var value = json[key] as! [String: Any]
            value["original_size"] = 100
            json[key] = value
        }
    }
    #expect(downsampled.pauses.isEmpty)
    let travelling = try ride { json in
        var distance = json["distance"] as! [String: Any]
        var values = distance["data"] as! [Double]
        for index in 7..<values.count { values[index] += 1000 }
        distance["data"] = values; json["distance"] = distance
    }
    #expect(travelling.pauses.isEmpty) // a long gap with travel is not a stationary break
    let noEvidence = try ride { $0.removeValue(forKey: "distance"); $0.removeValue(forKey: "latlng") }
    #expect(noEvidence.pauses.isEmpty)
    let detailURL = try #require(Bundle.module.url(forResource: "synthetic-ride", withExtension: "json", subdirectory: "Fixtures"))
    let streamsURL = try #require(Bundle.module.url(forResource: "synthetic-ride-streams", withExtension: "json", subdirectory: "Fixtures"))
    let source = try StravaJSON.decode(StravaActivity.self, from: Data(contentsOf: detailURL))
    let sparse = try source.activity(streams: StravaJSON.decode(StravaStreams.self, from: Data(contentsOf: streamsURL)))
    #expect(sparse.pauses.isEmpty)
}

@Test func missingMovingStreamCanUseStationaryGapButDoesNotInventEdgePauses() throws {
    let activity = try ride { $0.removeValue(forKey: "moving") }
    #expect(activity.pauses == [DateInterval(start: activity.start.addingTimeInterval(70), duration: 170)])
    let coordinatesOnly = try ride { $0.removeValue(forKey: "distance") }
    #expect(coordinatesOnly.pausedDuration == 180)
    let missingEdges = try ride { json in
        for key in Array(json.keys) {
            var stream = json[key] as! [String: Any]
            let values = stream["data"] as! [Any]
            stream["data"] = Array(values.dropFirst().dropLast())
            stream["original_size"] = values.count - 2
            json[key] = stream
        }
    }
    #expect(missingEdges.pausedDuration == 180)
    #expect(missingEdges.points.first?.date == missingEdges.start.addingTimeInterval(10))
    #expect(missingEdges.points.last?.date == missingEdges.end.addingTimeInterval(-10))
}

@Test func adjacentStationarySamplesMergeAndInvalidStreamsAreRejected() throws {
    let activity = try ride { json in
        var moving = json["moving"] as! [String: Any]
        var values = moving["data"] as! [Bool]
        values[5] = false
        moving["data"] = values; json["moving"] = moving
    }
    #expect(activity.pauses.count == 1)
    #expect(activity.pausedDuration == 190)
    #expect(throws: ImportProblem.self) {
        try ride { json in
            var moving = json["moving"] as! [String: Any]
            moving["data"] = [true]; json["moving"] = moving
        }
    }
    #expect(throws: ImportProblem.self) {
        try ride { json in
            var distance = json["distance"] as! [String: Any]
            var values = distance["data"] as! [Double]
            values[4] = 0
            distance["data"] = values; json["distance"] = distance
        }
    }
    let stationary = try ride { json in
        var moving = json["moving"] as! [String: Any]
        moving["data"] = Array(repeating: false, count: 14); json["moving"] = moving
    }
    #expect(stationary.pauses.isEmpty) // do not produce a zero-duration workout
}
