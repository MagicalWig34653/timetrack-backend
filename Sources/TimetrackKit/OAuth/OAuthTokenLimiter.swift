import Foundation

/// Process-local admission control, independent of the database's global authentication lock.
actor OAuthTokenLimiter {
    private var windows: [String: [Date]] = [:]
    func admit(ip: String, client: String? = nil, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-300)
        windows = windows.mapValues { $0.filter { $0 > cutoff } }.filter { !$0.value.isEmpty }
        // Connector services share IPs; keep the aggregate IP budget generous.
        let keys: [(String, Int)]
        if let client { keys = [("client:" + client, 120), ("pair:" + ip + ":" + client, 120)] }
        else { keys = [("ip:" + ip, 1200)] }
        guard keys.allSatisfy({ windows[$0.0, default: []].count < $0.1 }) else {
            throw OAuthError("temporarily_unavailable", "Too many token requests.", status: .tooManyRequests)
        }
        for (key, _) in keys { windows[key, default: []].append(now) }
    }
}
