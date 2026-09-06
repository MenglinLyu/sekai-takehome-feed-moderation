import Foundation
import os

/// Release-enabled intervals appear in Instruments' Points of Interest track.
/// Only opaque item IDs and phase metadata are recorded, never content URLs.
enum FeedPerformance {
    private static let log = OSLog(subsystem: "com.sekai.takehome", category: .pointsOfInterest)

    final class Interval {
        private let name: StaticString
        private let id: OSSignpostID
        private var ended = false

        fileprivate init(_ name: StaticString, detail: String) {
            self.name = name
            id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: name, signpostID: id, "%{public}@", detail)
        }

        func end(_ outcome: String = "completed") {
            guard !ended else { return }
            ended = true
            os_signpost(.end, log: log, name: name, signpostID: id, "%{public}@", outcome)
        }

        // Also closes intervals when a callback or its owner is released.
        deinit { end("released") }
    }

    static func begin(_ name: StaticString, _ detail: @autoclosure () -> String = "") -> Interval? {
        guard log.signpostsEnabled else { return nil }
        return Interval(name, detail: detail())
    }

    static func event(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard log.signpostsEnabled else { return }
        os_signpost(.event, log: log, name: name, "%{public}@", detail())
    }
}
