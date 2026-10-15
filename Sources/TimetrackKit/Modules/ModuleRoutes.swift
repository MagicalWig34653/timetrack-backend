import Fluent
import Vapor

/// One path-group policy covers every method, including future routes within these groups.
struct ModuleGuard: AsyncMiddleware {
    let auth: AuthService
    static func keys(for path: String) -> [ModuleKey] {
        let parts = path.split(separator: "/").map(String.init)
        if parts.first == "mcp" || parts.first == "oauth" || (parts.first == ".well-known" && parts.dropFirst().first?.hasPrefix("oauth-") == true) { return [.mcp] }
        guard parts.starts(with: ["api", "v1"]), parts.count > 2 else { return [] }
        switch parts[2] {
        case "reports": return [.reports]
        case "vacation", "calendar", "plan", "shares": return [.planning]
        case "absences": return parts.count > 4 && parts[4] == "attachments" ? [.planning, .transfer] : [.planning]
        case "export", "imports", "import-templates", "import-profiles", "files": return [.transfer]
        case "automation": return [.automation]
        case "oauth": return [.mcp]
        case "admin": return parts.dropFirst(3).first == "storage" ? [.transfer] : []
        case "time": return parts.dropFirst(3).first == "suggestions" ? [.automation] : []
        case "me":
            switch parts.dropFirst(3).first {
            case "device-tokens": return [.automation]
            case "oauth-grants", "api-tokens": return [.mcp]
            default: return []
            }
        default: return []
        }
    }
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let keys = Self.keys(for: req.url.path)
        if !keys.isEmpty {
            // Server visibility takes precedence; bearer account rejection remains 401 in authenticators.
            try await auth.modules.require(keys, account: nil, on: req.db)
            if let token = req.cookies["tt_session"]?.string {
                let context = try await auth.authenticate(token, on: req.db)
                try context.normal()
                try await auth.modules.require(keys, account: context.account.requireID(), on: req.db)
            }
        }
        return try await next.respond(to: req)
    }
}
func registerModuleRoutes(_ app: Application, auth: AuthService) {
    struct Input: Content { let modules: [String: Bool] }
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    api.get("modules") { req async throws -> [ModuleStatus] in
        let context = try req.authContext; try context.normal()
        return try await auth.modules.statuses(account: context.account.requireID(), on: req.db)
    }
    api.put("me", "modules") { req async throws -> [ModuleStatus] in
        let context = try req.authContext
        try await auth.modules.update(req.content.decode(Input.self).modules, context: context, server: false, auth: auth, on: req.db)
        return try await auth.modules.statuses(account: context.account.requireID(), on: req.db)
    }
    api.get("admin", "modules") { req async throws -> [ServerModule] in
        try req.authContext.admin(); return try await auth.modules.server(on: req.db)
    }
    api.put("admin", "modules") { req async throws -> [ServerModule] in
        let context = try req.authContext; try context.admin()
        try await auth.modules.update(req.content.decode(Input.self).modules, context: context, server: true, auth: auth, on: req.db)
        return try await auth.modules.server(on: req.db)
    }
}
