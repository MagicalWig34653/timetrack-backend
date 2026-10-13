import Vapor

@main
struct TimetrackBackend {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)
        let app = try await Application.make(environment)
        do {
            // Database configuration and domain services are the next implementation package.
            app.get("health") { _ in HealthResponse(status: "ok") }
            try await app.execute()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

struct HealthResponse: Content {
    let status: String
}
