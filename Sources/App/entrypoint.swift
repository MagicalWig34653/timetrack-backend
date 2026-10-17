import Foundation
import Vapor
import TimetrackKit

@main
struct TimetrackBackend {
    static func main() async throws {
        var environment = try Environment.detect()
        let timestamps = ProcessInfo.processInfo.environment["LOG_TIMESTAMPS"]?.lowercased() != "false"
        try LoggingSystem.bootstrap(from: &environment) { level in
            { label in TimestampedLogHandler(label: label, level: level, timestamps: timestamps) }
        }
        let app = try await Application.make(environment)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
