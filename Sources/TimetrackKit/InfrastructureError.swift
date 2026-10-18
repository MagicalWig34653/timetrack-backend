import Vapor
import Fluent
import AsyncKit
import MySQLNIO
import SQLiteNIO
import NIOCore
import NIOPosix
import NIOSSL

/// Classification of errors that mean "the infrastructure (database) is temporarily unreachable", as opposed to a
/// bug in the application. These are answered with 503 `database_unavailable` and `Retry-After` (ADR-0024).
enum InfrastructureError {
    enum Kind: String, Sendable, Equatable {
        case connectionFailed = "database connection failed"
        case connectionClosed = "database connection closed"
        case poolTimeout = "database pool timeout"
        case tlsFailure = "database TLS failure"
        case serverRefused = "database server refused the connection"
        case sqliteBusy = "sqlite database busy or unavailable"

        /// Seconds suggested to the client. A pool timeout means the server is overloaded: back off longer.
        var retryAfterSeconds: Int { self == .poolTimeout ? 5 : 2 }
    }

    /// Returns the kind when `error` (or an underlying error it wraps) is an infrastructure failure.
    static func classify(_ error: any Error) -> Kind? {
        classify(error, depth: 0)
    }

    /// SQLiteNIO's error initializer is internal, so the reason mapping is separate (and testable).
    static func classify(sqlite reason: SQLiteError.Reason) -> Kind? {
        switch reason {
        case .busy, .locked, .cantOpen, .busyTimeout, .ioError: .sqliteBusy
        default: nil
        }
    }

    private static func classify(_ error: any Error, depth: Int) -> Kind? {
        if depth > 4 { return nil }
        switch error {
        case let timeout as ConnectionPoolTimeoutError where timeout == .connectionRequestTimeout: return .poolTimeout
        case is ConnectionPoolError: return .connectionClosed
        case is NIOConnectionError: return .connectionFailed
        case is IOError: return .connectionFailed
        case is ChannelError, is NIOSSLError, is NIOSSLExtraError: return error is ChannelError ? .connectionClosed : .tlsFailure
        case let mysql as MySQLError:
            switch mysql {
            case .closed: return .connectionClosed
            case .server(let packet):
                // 1040 too many connections, 1053 server shutdown in progress, 1077/1078 shutdown, 1129/1130 host blocked,
                // 1203 user connection limit, 2002/2003/2006/2013 client-side connect/lost/gone-away codes.
                return [1040, 1053, 1129, 1203, 2002, 2003, 2006, 2013].contains(Int(packet.errorCode.rawValue)) ? .serverRefused : nil
            default: return nil
            }
        case let sqlite as SQLiteError: return classify(sqlite: sqlite.reason)
        default: break
        }
        // Wrappers that carry the real cause.
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error { return classify(underlying, depth: depth + 1) }
        return nil
    }
}
