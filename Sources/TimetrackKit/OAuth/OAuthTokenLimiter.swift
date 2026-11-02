import Foundation

/// Process-local admission control, independent of the database's global authentication lock.
actor OAuthTokenLimiter {
    private var windows: [String: [Date]] = [:]
    func admit(ip: String, client: String? = nil, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-300)
        windows = windows.mapValues { $0.filter { $0 > cutoff } }.filter { !$0.value.isEmpty }
        // Connector services share IPs; keep the aggregate IP budget generous.
        let keys: [(String, Int)]
        // SEC-11: the per-(client, IP) pair is the tight budget; the client-wide aggregate is only a generous ceiling, because
        // a client_id is public and a tight shared counter would let any caller lock the client out for everyone.
        if let client { keys = [("client:" + client, 1200), ("pair:" + ip + ":" + client, 120)] }
        else { keys = [("ip:" + ip, 1200)] }
        guard keys.allSatisfy({ windows[$0.0, default: []].count < $0.1 }) else {
            throw OAuthError("temporarily_unavailable", "Too many token requests.", status: .tooManyRequests)
        }
        for (key, _) in keys { windows[key, default: []].append(now) }
    }
}
