import Vapor
import Fluent

/// Entry point owned by package C12 (import). Registered from `registerRoutes`.
func registerImportRoutes(_ app: Application, auth: AuthService) {}

/// Migrations owned by package C12; appended after the stage 3a schema.
enum ImportSchema {
    static let migrations: [any Migration] = []
}
