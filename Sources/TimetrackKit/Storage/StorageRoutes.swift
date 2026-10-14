import Vapor
import Fluent

/// Entry point owned by package C13 (file storage and attachments). Registered from `registerRoutes`.
func registerStorageRoutes(_ app: Application, auth: AuthService) {}

/// Migrations owned by package C13; appended after the import schema.
enum StorageSchema {
    static let migrations: [any Migration] = []
}
