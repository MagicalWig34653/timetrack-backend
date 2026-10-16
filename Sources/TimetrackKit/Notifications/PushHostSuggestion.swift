import Foundation

extension PushEndpointPolicy {
    /// Documented, tested value for `PUSH_ALLOWED_HOSTS` (EINRICHTUNG.md, ADR-0017): one real host pattern per push service
    /// of the common browsers: Google FCM (Chrome, Edge, Samsung Internet, Android), Mozilla autopush (Firefox),
    /// Apple Web Push (Safari, installed PWAs) and Windows WNS (`*.notify.windows.com`, regional subdomains).
    /// It is not a default: the built-in list stays as fixed by ADR-0011 and `PUSH_ALLOWED_HOSTS` replaces it entirely.
    static let documentedAllowedHosts = ["fcm.googleapis.com", "updates.push.services.mozilla.com", "web.push.apple.com", "*.notify.windows.com"]
}
