import Vapor

/// Entry point owned by package C11 (export). Registered from `registerRoutes`.
func registerExportRoutes(_ app: Application, auth: AuthService) {}
