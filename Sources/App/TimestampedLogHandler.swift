import Foundation
import Logging
import NIOConcurrencyHelpers
import TimetrackKit

/// Console log handler that prefixes every line with a UTC timestamp (ISO 8601, millisecond precision), so that
/// `docker logs` output stays meaningful when it is copied, filtered or stored without Docker's own timestamps.
/// Format: `2026-10-17T14:05:03.123Z [ NOTICE ] message [key: value, …]`. Set `LOG_TIMESTAMPS=false` to omit the prefix.
struct TimestampedLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level
    private let label: String
    private let timestamps: Bool

    private static let lock = NIOLock()

    init(label: String, level: Logger.Level, timestamps: Bool = true) {
        self.label = label; self.logLevel = level; self.timestamps = timestamps
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(level: Logger.Level, message: Logger.Message, metadata explicit: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let merged = metadata.merging(explicit ?? [:]) { _, new in new }
        var text = timestamps ? Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) + " " : ""
        text += "[ \(level.rawValue.uppercased()) ] \(TriggerTokenScrubber.scrub(message.description))"
        if !merged.isEmpty {
            text += " [" + merged.sorted { $0.key < $1.key }.map { "\($0.key): \(TriggerTokenScrubber.scrub("\($0.value)"))" }.joined(separator: ", ") + "]"
        }
        Self.lock.withLockVoid {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
    }
}
