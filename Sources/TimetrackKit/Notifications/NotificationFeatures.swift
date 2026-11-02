import Foundation

/// Decides Web Push (VAPID), APNs and the reminder runner from the (sanitized) environment, following the shared rule of
/// `FeatureSwitches.swift`: `WEB_PUSH_ENABLED` and `APNS_ENABLED` are true, false or empty (automatic = on when complete).
/// Automatic mode keeps the earlier behaviour: an incomplete or invalid configuration only logs a warning. `true` turns the
/// same situation into a start error. Messages name variables only, never values.
struct NotificationFeatures {
    var vapid: VapidConfiguration?
    var apns: ApnsConfiguration?
    /// The APNS_* variables the admin diagnostics may look at (empty when APNs is switched off).
    var apnsEnvironment: [String: String] = [:]
    var statuses: [FeatureStatus] = []
    var warnings: [String] = []

    static func vapidProblems(_ environment: [String: String]) -> [String] {
        var result: [String] = []
        let key = environment["VAPID_PRIVATE_KEY"]
        let subject = environment["VAPID_SUBJECT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == nil { result.append("VAPID_PRIVATE_KEY") }
        else if VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": key!, "VAPID_SUBJECT": "mailto:a@b.cd"]) == nil { result.append("VAPID_PRIVATE_KEY (invalid)") }
        if subject == nil { result.append("VAPID_SUBJECT") }
        else if !VapidConfiguration.validSubject(subject!) { result.append("VAPID_SUBJECT (invalid)") }
        return result
    }

    static func evaluate(environment: [String: String]) throws -> NotificationFeatures {
        var result = NotificationFeatures()
        // Web Push
        switch try FeatureMode.read("WEB_PUSH_ENABLED", in: environment) {
        case .disabled:
            result.statuses.append(.offBySwitch("Web Push", "WEB_PUSH_ENABLED"))
        case let mode:
            result.vapid = VapidConfiguration(environment: environment)
            if let vapid = result.vapid {
                result.statuses.append(.on("Web Push", "VAPID key and subject set, subject=\(vapid.subject)"))
            } else {
                let problems = vapidProblems(environment)
                if mode == .enabled {
                    throw ConfigurationError(key: "WEB_PUSH_ENABLED", reason: "set to true, but incomplete or invalid: \(problems.joined(separator: ", "))")
                }
                // Both missing = never configured: just "off". Partly present: tell the operator which part is wrong.
                if environment["VAPID_PRIVATE_KEY"] != nil || environment["VAPID_SUBJECT"] != nil {
                    result.warnings.append("VAPID_PRIVATE_KEY/VAPID_SUBJECT are invalid or incomplete (\(problems.joined(separator: ", "))): Web Push stays unavailable")
                }
                result.statuses.append(.off("Web Push", problems.isEmpty ? "not configured" : "not configured: \(problems.joined(separator: ", "))"))
            }
        }
        // APNs
        switch try FeatureMode.read("APNS_ENABLED", in: environment) {
        case .disabled:
            result.statuses.append(.offBySwitch("APNs", "APNS_ENABLED"))
        case let mode:
            result.apns = ApnsConfiguration(environment: environment)
            result.apnsEnvironment = environment.filter { $0.key.hasPrefix("APNS_") }
            if let apns = result.apns {
                result.statuses.append(.on("APNs", "key id=\(apns.keyId) team id=\(apns.teamId) bundle IDs=\(apns.bundleIds.sorted().joined(separator: ","))"))
            } else {
                let configured = ApnsConfiguration.anyConfigured(environment)
                let problems = configured ? ApnsDiagnosis.problems(environment) : ["APNS_PRIVATE_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_IDS"]
                if mode == .enabled {
                    throw ConfigurationError(key: "APNS_ENABLED", reason: "set to true, but incomplete or invalid: \(problems.joined(separator: ", "))")
                }
                if configured { result.warnings.append("APNS_* settings are invalid or incomplete (\(problems.joined(separator: ", "))): APNs push stays unavailable") }
                result.statuses.append(.off("APNs", configured ? "incomplete or invalid: \(problems.joined(separator: ", "))" : "not configured"))
            }
        }
        // Reminder runner
        let notifications = environment["NOTIFICATIONS_ENABLED"]?.lowercased()
        result.statuses.append(notifications == "false" ? .offBySwitch("Reminders", "NOTIFICATIONS_ENABLED") : .on("Reminders", "background runner"))
        return result
    }
}
